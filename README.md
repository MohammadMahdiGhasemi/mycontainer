# mycontainer

A lightweight Linux container runtime built from scratch using only Bash and Linux kernel primitives — no Docker, no runc, no containerd.

Demonstrates how Linux containers work internally for university presentations.

## What This Project Shows

| Feature | How It Works |
|---------|-------------|
| **Process isolation** | `unshare --pid` creates a new PID namespace — container sees only its own processes |
| **Filesystem isolation** | `unshare --mount` + `chroot` — container has its own mount table and root directory |
| **Hostname isolation** | `unshare --uts` — container has its own hostname |
| **IPC isolation** | `unshare --ipc` — shared memory and semaphores are separate |
| **Network sharing** | Host network is shared so DNS and `apt` work |
| **Copy-on-write** | `overlayfs` layers a writable layer on top of a read-only rootfs |
| **Resource limits** | cgroups v2 CPU and memory limits (when available) |
| **Rootless** | `unshare --user --map-root-user` — no sudo needed |

## Project Structure

```
mycontainer/
├── mycontainer          # CLI entry point
├── containerd/
│   ├── run.sh           # create & start container
│   ├── exec.sh          # enter running container
│   └── stop.sh          # stop & cleanup
├── rootfs/              # Debian minimal filesystem (debootstrap)
├── state/
│   └── containers/      # per-container state
└── README.md
```

## Quick Start

### 1. Create the rootfs (requires root, one-time)

```bash
sudo debootstrap --variant=minbase bookworm rootfs
```

Or use an existing rootfs directory.

### 2. Run the container

```bash
./mycontainer run demo
```

You'll get a shell inside the container:

```
[Container demo started]  Type 'exit' to stop.
  PID namespace:  isolated (PID 1 = this shell)
  Mount namespace: isolated (overlayfs)
  UTS namespace:   isolated (hostname=demo)
  IPC namespace:   isolated
  NET namespace:   shared (host network)
bash-5.2#
```

### 3. Install packages

```bash
./mycontainer exec demo 'apt install -y python3'
./mycontainer exec demo 'python3 --version'
```

### 4. Stop the container

```bash
./mycontainer stop demo
```

## CLI Reference

```
mycontainer run <name>              # start interactive container
mycontainer exec <name> [command]   # run command in container
mycontainer exec <name> bash        # attach interactive shell
mycontainer stop <name>             # stop and cleanup
mycontainer list                    # show all containers
mycontainer help                    # show help
```

## How It Works

### The Run Flow

```
mycontainer run demo
    │
    ▼
run.sh
    ├── Validate rootfs exists
    ├── Copy rootfs to state/containers/demo/merged/ (first time)
    ├── Create cgroup (if available)
    │
    ▼
unshare --user --map-root-user --fork --pid --mount --uts --ipc
    │
    ▼
Inside new namespaces (as root):
    ├── mount -t proc proc merged/proc        # isolate process list
    ├── mount -t sysfs sysfs merged/sys       # kernel info
    ├── mount --bind /dev/null merged/dev/    # essential devices
    ├── hostname demo                         # set container hostname
    ├── cp /etc/resolv.conf merged/etc/       # DNS config
    │
    ▼
chroot merged /bin/bash
    │
    ▼
Interactive shell with isolated PID/mount/UTS/IPC
```

### The Exec Flow

```
mycontainer exec demo ls /
    │
    ▼
exec.sh
    ├── Check container state exists
    │
    ▼
unshare --user --map-root-user --fork --pid --mount --uts --ipc
    │
    ▼
Mount proc/sys/dev, then:
chroot merged /bin/bash -c "ls /"
```

### Namespace Isolation

| Namespace | Flag | What It Isolates |
|-----------|------|------------------|
| PID | `--pid` | Process IDs — container init is PID 1, only sees its own processes |
| Mount | `--mount` | Mount points — container's `/proc`, `/sys` don't affect host |
| UTS | `--uts` | Hostname — `hostname demo` doesn't change the host |
| IPC | `--ipc` | Shared memory, semaphores, message queues |
| User | `--user` | User/group IDs — gives us root inside without real root |

### User Namespaces (Rootless Containers)

```bash
unshare --user --map-root-user
```

This creates a user namespace where your UID (1000) is mapped to root (0). Inside the namespace, you have full capabilities (`CAP_SYS_ADMIN`, `CAP_NET_ADMIN`, etc.). This is how Docker and Podman run without root.

### OverlayFS (Copy-on-Write)

```
lowerdir = rootfs/          # read-only base (Debian minimal)
upperdir = state/upper/     # writable layer (new/modified files)
workdir  = state/work/      # scratch space for atomic operations
merged   = state/merged/    # combined view the container sees
```

When a file in `lowerdir` is modified, overlayfs copies it to `upperdir` first, then modifies the copy. The original stays unchanged. This is exactly how Docker images work.

**Fallback:** In nested user namespaces (inside Docker/WSL2), overlayfs copy-up may fail for directories with unmapped UIDs. The scripts detect this and fall back to a writable copy of the rootfs.

### cgroups v2 Resource Limits

```bash
# CPU: 50% of one core
echo "50000 100000" > /sys/fs/cgroup/mycontainer_demo/cpu.max

# Memory: 256 MB
echo 268435456 > /sys/fs/cgroup/mycontainer_demo/memory.max
```

cgroups are created automatically when `run` starts. Requires a system with cgroups v2 support.

## Limitations

These are educational limitations, not bugs — they reflect real kernel constraints:

1. **No `apt update` in isolated network mode** — the network namespace has only loopback. This is by design: network isolation is a core container feature. The default config shares the host network so `apt` works.

2. **OverlayFS fallback in nested containers** — if you're running this inside Docker/WSL2, overlayfs may not support copy-up for root-owned directories. The scripts automatically fall back to a writable copy.

3. **No `nsenter` into running containers** — in user namespace mode, `nsenter` can't cross namespace boundaries. The `exec` command creates a new namespace session that shares the same filesystem.

4. **Single-host only** — no container networking, no image registry, no orchestration. This is a minimal runtime for understanding concepts.

## Differences from Docker

| Feature | mycontainer | Docker |
|---------|-------------|--------|
| Runtime | Bash scripts | Go (containerd + runc) |
| Root | User namespace (rootless) | Requires root or rootless mode |
| Filesystem | Copy or overlay | OverlayFS with storage drivers |
| Network | Shared host network | Bridge networking with iptables |
| Images | Local debootstrap | Registry (Docker Hub) |
| Orchestration | Single host | Swarm, Kubernetes |

## Requirements

- Linux with kernel ≥ 4.18 (for unprivileged user namespaces)
- `bash`, `unshare`, `chroot`, `nsenter` (from util-linux)
- Debian/Ubuntu-based system (for debootstrap)

## Creating the Rootfs

```bash
# Install debootstrap (on Debian/Ubuntu)
sudo apt install debootstrap

# Create minimal Debian rootfs
sudo debootstrap --variant=minbase bookworm rootfs

# Or create a more complete one
sudo debootstrap --variant=minbase --include=apt-transport-https,ca-certificates \
    bookworm rootfs
```
.
