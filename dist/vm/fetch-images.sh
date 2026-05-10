#!/usr/bin/env bash
# Pull the base docker image we'll build the rootfs from. Optional — `docker
# build` would pull it on demand anyway, but doing it up front surfaces
# daemon/network errors before the longer rootfs build.
set -euo pipefail

cd "$(dirname "$0")"

# shellcheck source=distros.sh
. ./distros.sh
distro_setup

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker is required" >&2
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "error: docker daemon not reachable. Start it with: sudo systemctl start docker" >&2
    exit 1
fi

echo ">> docker pull $BASE"
docker pull "$BASE"

echo "ok. Next: ./build-rootfs.sh (needs sudo for the loop mount)."
