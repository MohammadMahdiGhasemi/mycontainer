#!/bin/bash
#
# stop.sh - Stop a running container and clean up its resources
#
# Steps:
#   1. Find the container's main process by reading its PID file
#   2. Send SIGTERM first (graceful shutdown), then SIGKILL if needed
#   3. Wait for the process to exit
#   4. Remove the container's state directory (shared filesystem)
#
set -euo pipefail

NAME="${1:-}"
BASE="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$BASE/state/containers"
CONTAINER_DIR="$STATE/$NAME"
MERGED="$CONTAINER_DIR/merged"

# --- Validate arguments ---
if [ -z "$NAME" ]; then
    echo "Usage: mycontainer stop <name>" >&2
    exit 1
fi

# --- Check container exists ---
if [ ! -d "$CONTAINER_DIR" ]; then
    echo "[!] Container '$NAME' does not exist" >&2
    exit 1
fi

PID=$(cat "$CONTAINER_DIR/pid" 2>/dev/null || echo "")

if [ -z "$PID" ]; then
    echo "[*] Container '$NAME' is not running (no PID file)"
    echo "[*] Cleaning up stale state..."
else
    if kill -0 "$PID" 2>/dev/null; then
        echo "[+] Stopping container '$NAME' (PID $PID)"

        # SIGTERM: graceful shutdown
        kill -TERM "$PID" 2>/dev/null || true

        # Wait up to 5 seconds for graceful shutdown
        TIMEOUT=5
        ELAPSED=0
        while kill -0 "$PID" 2>/dev/null && [ "$ELAPSED" -lt "$TIMEOUT" ]; do
            sleep 0.2
            ELAPSED=$((ELAPSED + 1))
        done

        # SIGKILL: forced shutdown if SIGTERM didn't work
        if kill -0 "$PID" 2>/dev/null; then
            echo "[!] Graceful shutdown timed out, sending SIGKILL"
            kill -KILL "$PID" 2>/dev/null || true
            sleep 0.2
        fi

        echo "[+] Container '$NAME' stopped"
    else
        echo "[*] Container '$NAME' process (PID $PID) already exited"
    fi
fi

# --- Cleanup: unmount anything in merged directory ---
if [ -d "$MERGED" ]; then
    for dev in "$MERGED/dev/"*; do
        [ -e "$dev" ] && umount "$dev" 2>/dev/null || true
    done
    umount "$MERGED/sys" 2>/dev/null || true
    umount "$MERGED/proc" 2>/dev/null || true
    umount "$MERGED" 2>/dev/null || true
fi

# --- Remove state directory ---
rm -rf "$CONTAINER_DIR"
echo "[+] State cleaned up for '$NAME'"
echo "[+] Container '$NAME' removed"
