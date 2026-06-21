#!/bin/bash
#
# exec.sh - Execute a command inside a running container's filesystem
#
# Chroots into the same directory that run.sh uses. Package installs
# and file changes from "run" are visible here.
#
set -euo pipefail

NAME="${1:-}"
CMD="${2:-/bin/bash}"
BASE="$(cd "$(dirname "$0")/.." && pwd)"
ROOTFS="$BASE/rootfs"
STATE="$BASE/state/containers"
CONTAINER_DIR="$STATE/$NAME"
MERGED="$CONTAINER_DIR/merged"

# --- Validate arguments ---
if [ -z "$NAME" ]; then
    echo "Usage: mycontainer exec <name> [command]" >&2
    exit 1
fi

# --- Check container exists ---
if [ ! -d "$CONTAINER_DIR" ] || [ ! -d "$MERGED" ]; then
    echo "[!] Container '$NAME' does not exist. Run 'mycontainer run $NAME' first." >&2
    exit 1
fi

# --- Check rootfs ---
if [ ! -d "$ROOTFS" ] || [ ! -x "$ROOTFS/bin/sh" ]; then
    echo "[!] Rootfs not found at $ROOTFS" >&2
    exit 1
fi

PID=$(cat "$CONTAINER_DIR/pid" 2>/dev/null || echo "")

if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    echo "[+] Entering container '$NAME' (running, PID $PID)"
else
    echo "[*] Container '$NAME' process not running - using last filesystem state"
    rm -f "$CONTAINER_DIR/pid"
fi

echo "    Command: $CMD"
echo ""

# --- Cleanup function ---
do_cleanup() {
    for mp in "$MERGED/dev/"* "$MERGED/sys" "$MERGED/proc"; do
        umount "$mp" 2>/dev/null || true
    done
}
trap do_cleanup EXIT

# ============================================================================
# CREATE NAMESPACES AND ENTER CONTAINER
#
# Chroots into the SAME directory that run.sh uses.
# No filesystem mounting needed - just proc/sys/dev for the chroot.
# ============================================================================
unshare \
    --user --map-root-user \
    --fork \
    --pid --mount --uts --ipc \
    bash -c '
        set -euo pipefail

        MERGED="'"$MERGED"'"
        NAME="'"$NAME"'"
        CMD="'"$CMD"'"

        # --- Mount /proc ---
        mount -t proc proc "$MERGED/proc"

        # --- Mount /sys (best-effort) ---
        mount -t sysfs sysfs "$MERGED/sys" 2>/dev/null || true

        # --- Bind-mount essential devices ---
        mkdir -p "$MERGED/dev"
        for dev in null zero random urandom tty; do
            if [ -e "/dev/$dev" ]; then
                touch "$MERGED/dev/$dev" 2>/dev/null || true
                mount --bind "/dev/$dev" "$MERGED/dev/$dev" 2>/dev/null || true
            fi
        done

        # --- Set hostname ---
        hostname "${NAME}-exec"

        # --- Execute the command inside chroot ---
        if [ "$CMD" = "/bin/bash" ]; then
            exec chroot "$MERGED" /bin/bash --norc --noprofile -c "
                export TERM=xterm-256color
                export HOME=/root
                export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
                export LANG=C.UTF-8
                echo \"[Attached to container '$NAME' filesystem]\"
                echo \"  PID namespace:  new (this session)\"
                echo \"  Mount namespace: new (shared filesystem)\"
                echo \"  Hostname: ${NAME}-exec\"
                exec /bin/bash --norc --noprofile
            "
        else
            exec chroot "$MERGED" /bin/bash --norc --noprofile -c "$CMD"
        fi
    '
