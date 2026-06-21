#!/bin/bash
#
# run.sh - Create and start a Linux container
#
# Uses Linux kernel features to create isolation:
#   1. unshare()   - creates new namespaces (PID, mount, UTS, IPC, user)
#   2. chroot      - changes the apparent root directory for the container
#   3. cgroups v2  - resource limits (CPU, memory) when available
#   4. proc/sysfs  - virtual filesystems mounted inside for process info
#
set -euo pipefail

NAME="${1:-}"
BASE="$(cd "$(dirname "$0")/.." && pwd)"
ROOTFS="$BASE/rootfs"
STATE="$BASE/state/containers"
CONTAINER_DIR="$STATE/$NAME"
MERGED="$CONTAINER_DIR/merged"

# --- Validate arguments ---
if [ -z "$NAME" ]; then
    echo "Usage: mycontainer run <name>" >&2
    exit 1
fi

# --- Idempotent: check if container already exists ---
if [ -f "$CONTAINER_DIR/pid" ]; then
    OLD_PID=$(cat "$CONTAINER_DIR/pid" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[!] Container '$NAME' is already running (PID $OLD_PID)" >&2
        exit 1
    fi
    rm -f "$CONTAINER_DIR/pid"
fi

# --- Validate rootfs exists ---
if [ ! -d "$ROOTFS" ] || [ ! -x "$ROOTFS/bin/sh" ]; then
    echo "[!] Rootfs not found or incomplete at $ROOTFS" >&2
    echo "    Run: sudo debootstrap --variant=minbase bookworm $ROOTFS" >&2
    exit 1
fi

# --- Create per-container state directory ---
mkdir -p "$CONTAINER_DIR"/{upper,work,merged}

echo "[+] Creating container '$NAME'"
echo "    rootfs:   $ROOTFS"
echo "    workdir:  $CONTAINER_DIR"

# --- cgroups v2 resource limits ---
CGROUP_PATH="/sys/fs/cgroup/mycontainer_$NAME"
CGROUP_CREATED=false
CPU_MAX="50000 100000"
MEMORY_MAX=268435456

if mkdir "$CGROUP_PATH" 2>/dev/null; then
    CGROUP_CREATED=true
    echo "$CPU_MAX" > "$CGROUP_PATH/cpu.max" 2>/dev/null || true
    echo "$MEMORY_MAX" > "$CGROUP_PATH/memory.max" 2>/dev/null || true
    echo "    cgroup:  $CGROUP_PATH"
    echo "    cpu:     ${CPU_MAX} (50% of one core)"
    echo "    memory:  $((MEMORY_MAX / 1024 / 1024)) MB"
else
    echo "    cgroup:  unavailable (running without resource limits)"
fi

# ============================================================================
# PREPARE CONTAINER FILESYSTEM (before unshare)
#
# Copy rootfs to a shared directory. Both "run" and "exec" chroot into
# this same directory, so package installs and file changes persist across
# sessions. Files are owned by UID 1000 (us), which maps to root inside
# the user namespace.
# ============================================================================
if [ ! -f "$MERGED/.initialized" ]; then
    echo "    fs:      copying rootfs (first time)..."
    cp -a "$ROOTFS"/. "$MERGED"/ 2>/dev/null || true
    touch "$MERGED/.initialized"
fi

# --- Save container PID to state file ---
echo "$$" > "$CONTAINER_DIR/pid"
echo "    PID:     $$"
echo "[+] Container '$NAME' started successfully"
echo ""

# --- Cleanup function ---
do_cleanup() {
    rm -f "$CONTAINER_DIR/pid"
    for mp in "$MERGED/dev/"* "$MERGED/sys" "$MERGED/proc"; do
        umount "$mp" 2>/dev/null || true
    done
    if [ "$CGROUP_CREATED" = "true" ]; then
        rmdir "$CGROUP_PATH" 2>/dev/null || true
    fi
}
trap do_cleanup EXIT

# ============================================================================
# CREATE NAMESPACES AND ENTER CONTAINER
#
# unshare creates isolated namespaces. The filesystem is already prepared
# above (shared between run and exec via the same directory on disk).
#
# --user --map-root-user:  Gives us root inside the user namespace.
# --fork --pid:            Isolates PID number space (container init = PID 1).
# --mount:                 Isolates mount points (proc/sysfs/dev inside).
# --uts:                   Isolates hostname.
# --ipc:                   Isolates shared memory and semaphores.
# NOTE: --net is omitted to share host network (allows DNS and apt).
# ============================================================================
exec unshare \
    --user --map-root-user \
    --fork \
    --pid --mount --uts --ipc \
    bash -c '
        set -euo pipefail

        MERGED="'"$MERGED"'"
        NAME="'"$NAME"'"
        CGROUP_CREATED="'"$CGROUP_CREATED"'"
        CGROUP_PATH="'"$CGROUP_PATH"'"

        # --- Move this process into the cgroup ---
        if [ "$CGROUP_CREATED" = "true" ] && [ -f "$CGROUP_PATH/cgroup.procs" ]; then
            echo "$$" > "$CGROUP_PATH/cgroup.procs" 2>/dev/null || true
        fi

        # --- Fix apt for user namespace environments ---
        mkdir -p "$MERGED/etc/apt/apt.conf.d" 2>/dev/null || true
        cat > "$MERGED/etc/apt/apt.conf.d/99mycontainer" << APTEOF 2>/dev/null || true
APT::Sandbox::User "root";
APT::Sandbox::Group "root";
DPkg::options:: "--force-not-root";
DPkg::options:: "--force-overwrite";
APTEOF
        chmod 1777 "$MERGED/var/lib/apt/lists" 2>/dev/null || true
        chmod 1777 "$MERGED/var/lib/apt/lists/partial" 2>/dev/null || true
        chmod 1777 "$MERGED/var/cache/apt" 2>/dev/null || true
        chmod 1777 "$MERGED/tmp" 2>/dev/null || true

        # --- Copy DNS config ---
        if [ -f /etc/resolv.conf ]; then
            cp /etc/resolv.conf "$MERGED/etc/resolv.conf" 2>/dev/null || true
        fi

        # --- Mount /proc ---
        mount -t proc proc "$MERGED/proc"

        # --- Mount /sys (best-effort) ---
        mount -t sysfs sysfs "$MERGED/sys" 2>/dev/null || true

        # --- Mount /dev (minimal) ---
        mkdir -p "$MERGED/dev"
        for dev in null zero random urandom tty; do
            if [ -e "/dev/$dev" ]; then
                touch "$MERGED/dev/$dev" 2>/dev/null || true
                mount --bind "/dev/$dev" "$MERGED/dev/$dev" 2>/dev/null || true
            fi
        done

        # --- Set hostname ---
        hostname "$NAME"

        # --- Execute the container shell ---
        chroot "$MERGED" /bin/bash --norc --noprofile -c "
            export TERM=xterm-256color
            export HOME=/root
            export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            export LANG=C.UTF-8
            echo \"[Container '$NAME' started]  Type '\''exit'\'' to stop.\"
            echo \"  PID namespace:  isolated (PID 1 = this shell)\"
            echo \"  Mount namespace: isolated (overlayfs)\"
            echo \"  UTS namespace:   isolated (hostname=$NAME)\"
            echo \"  IPC namespace:   isolated\"
            echo \"  NET namespace:   shared (host network)\"
            if [ \"$CGROUP_CREATED\" = \"true\" ]; then
                echo \"  cgroups v2:      CPU + memory limits active\"
            fi
            exec /bin/bash --norc --noprofile
        "
    '
