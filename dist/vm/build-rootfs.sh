#!/usr/bin/env bash
# Build /tmp/fcghar/rootfs.xfs + kernel + initrd from a Debian/Ubuntu docker
# image plus everything in overlays/. Bakes the actions-runner tarball in
# pre-extracted under /home/gha/runner; if PROJECT/URL + TOKEN are set, also
# bakes /etc/fcghar/register.env so gha-register.service auto-registers on
# first boot.
#
# The mount + tar-extract step needs sudo. Everything else is unprivileged.
set -euo pipefail

cd "$(dirname "$0")"

# shellcheck source=distros.sh
. ./distros.sh
distro_setup

DISTRO="${DISTRO:-debian-trixie}"
ROOT_SIZE_MB="${ROOT_SIZE_MB:-10240}"
IMAGE_TAG="fcghar-rootfs:$DISTRO"
FCGHAR_VAR="${FCGHAR_VAR:-/tmp/fcghar}"
OUT_FS="$FCGHAR_VAR/rootfs.xfs"
KERNEL_OUT="$FCGHAR_VAR/vmlinux"
INITRD_OUT="$FCGHAR_VAR/initrd"

RUNNER_VERSION="${RUNNER_VERSION:-2.334.0}"
RUNNER_SHA256="${RUNNER_SHA256:-048024cd2c848eb6f14d5646d56c13a4def2ae7ee3ad12122bee960c56f3d271}"

mkdir -p "$FCGHAR_VAR"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "error: docker daemon not available (start with: sudo systemctl start docker)" >&2
    exit 1
fi

if ! command -v mkfs.xfs >/dev/null 2>&1; then
    echo "error: mkfs.xfs not found (install xfsprogs)" >&2
    exit 1
fi

echo ">> building docker image $IMAGE_TAG ($BASE + actions-runner $RUNNER_VERSION + overlays)"
BUILD_CTX=$(mktemp -d)
trap 'rm -rf "$BUILD_CTX"' EXIT

cp -a overlays "$BUILD_CTX/overlays"

# Stage authorized_keys from the invoking user's pubkeys for root@VM ssh.
USER_HOME="${SUDO_USER:+/home/$SUDO_USER}"
USER_HOME="${USER_HOME:-$HOME}"
if compgen -G "$USER_HOME/.ssh/id_*.pub" >/dev/null; then
    cat "$USER_HOME"/.ssh/id_*.pub > "$BUILD_CTX/authorized_keys"
    echo "   staged $(wc -l < "$BUILD_CTX/authorized_keys") authorized_keys entry(ies) from $USER_HOME/.ssh/"
else
    : > "$BUILD_CTX/authorized_keys"
    echo "   warning: no $USER_HOME/.ssh/id_*.pub found — sshd will reject all logins" >&2
fi

DOCKERFILE="$BUILD_CTX/Dockerfile"

# --- distro-specific head: base image + packages + service masking ---
case "$PKG_MGR" in
    apt)
        cat > "$DOCKERFILE" <<EOF
FROM ${BASE}

ENV DEBIAN_FRONTEND=noninteractive

# systemd-sysv provides /sbin/init -> systemd. ${KERNEL_PKG} brings the kernel
# + modules. The runner's own bin/installdependencies.sh handles libicu/libssl
# per distro and runs further down.
RUN apt-get update && apt-get install -y --no-install-recommends \\
        systemd systemd-sysv dbus \\
        ${KERNEL_PKG} \\
        ca-certificates curl \\
        git jq sudo \\
        iproute2 iputils-ping \\
        openssh-server \\
        kmod udev \\
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Drop services that stall boot in a minimal microVM.
RUN systemctl mask \\
        systemd-networkd-wait-online.service \\
        systemd-timesyncd.service \\
        apt-daily.service apt-daily.timer apt-daily-upgrade.service apt-daily-upgrade.timer
EOF
        ;;
    pacman)
        cat > "$DOCKERFILE" <<EOF
FROM ${BASE}

# pacman -Syu refreshes the keyring + upgrades all base packages, then pulls
# in everything we need. installdependencies.sh doesn't speak pacman, so we
# install the runner's runtime deps (icu/openssl/krb5/zlib/lttng-ust) here.
RUN pacman -Syu --noconfirm \\
        systemd dbus \\
        ${KERNEL_PKG} mkinitcpio \\
        ca-certificates curl \\
        git jq sudo \\
        iproute2 iputils \\
        openssh \\
        icu openssl krb5 zlib lttng-ust \\
        kmod udev \\
    && pacman -Scc --noconfirm

# mkinitcpio's default HOOKS use 'autodetect', which strips out modules the
# build host doesn't load — i.e. virtio_blk. Bake them in explicitly so the
# initramfs can find /dev/vda when firecracker boots.
RUN sed -i \\
        -e 's|^MODULES=.*|MODULES=(virtio virtio_blk virtio_net virtio_pci xfs)|' \\
        -e 's|^HOOKS=.*|HOOKS=(base systemd modconf block filesystems)|' \\
        /etc/mkinitcpio.conf \\
    && mkinitcpio -P

# systemd-networkd is enabled by default on Arch and races our fcghar-network
# for eth0; mask it. systemd-firstboot otherwise grabs the serial console at
# boot and asks for timezone/locale. Pre-set locale + tz so nothing else
# tries to be interactive.
RUN systemctl mask \\
        systemd-networkd-wait-online.service \\
        systemd-networkd.service \\
        systemd-networkd.socket \\
        systemd-timesyncd.service \\
        systemd-firstboot.service \\
    && echo 'LANG=C.UTF-8' > /etc/locale.conf \\
    && ln -sf /usr/share/zoneinfo/UTC /etc/localtime
EOF
        ;;
    *)
        echo "error: unsupported PKG_MGR '$PKG_MGR'" >&2; exit 2 ;;
esac

# --- common middle: serial console + sshd + gha user + runner download ---
cat >> "$DOCKERFILE" <<EOF

# Allow root login on the serial console without a password (debug aid only).
RUN passwd -d root \\
    && systemctl enable serial-getty@ttyS0.service

# sshd: root key-only login, no passwords, no challenge-response.
COPY authorized_keys /root/.ssh/authorized_keys
RUN chmod 700 /root/.ssh \\
    && chmod 600 /root/.ssh/authorized_keys \\
    && sed -i \\
        -e 's/^#\\?PermitRootLogin.*/PermitRootLogin prohibit-password/' \\
        -e 's/^#\\?PasswordAuthentication.*/PasswordAuthentication no/' \\
        -e 's/^#\\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' \\
        /etc/ssh/sshd_config \\
    && systemctl enable ${SSHD_SVC}

RUN printf '/dev/vda / xfs defaults 0 0\\n' > /etc/fstab \\
    && printf 'fcghar\\n' > /etc/hostname

# gha user runs the actions-runner. Passwordless sudo for workflows that
# need root (apt, docker, etc.).
RUN useradd -m -s /bin/bash gha \\
    && echo 'gha ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/gha \\
    && chmod 0440 /etc/sudoers.d/gha

# Download + verify + extract the runner tarball as gha. Registration
# (config.sh with --url and --token) is deferred to first boot.
USER gha
WORKDIR /home/gha
RUN curl -fsSL -o actions-runner.tar.gz \\
        https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \\
    && echo "${RUNNER_SHA256}  actions-runner.tar.gz" | sha256sum -c - \\
    && mkdir -p runner \\
    && tar xzf actions-runner.tar.gz -C runner \\
    && rm actions-runner.tar.gz

USER root
EOF

# --- distro-specific deps: apt-only (pacman branch already installed deps) ---
if [ "$PKG_MGR" = "apt" ]; then
    cat >> "$DOCKERFILE" <<'EOF'
# Runner ships its own apt/dnf deps installer; runs once at build time.
RUN /home/gha/runner/bin/installdependencies.sh
EOF
fi

# --- common tail: overlays + /etc/fcghar + service enable ---
cat >> "$DOCKERFILE" <<'EOF'

# Overlays (systemd units, network helper, resolv.conf).
COPY overlays/ /

# /etc/fcghar/ holds register.env (URL/TOKEN, written into the rootfs at
# build-time below) and the .registered touchfile that gha-register.service
# uses to skip itself on subsequent boots.
RUN mkdir -p /etc/fcghar \
    && touch /etc/fcghar/register.env \
    && chmod 0600 /etc/fcghar/register.env \
    && chmod 0755 /usr/local/bin/fcghar-network /usr/local/bin/gha-register

# Per-VM network from kernel cmdline. gha-register fires once at first boot,
# touches /etc/fcghar/.registered, then gha.service starts run.sh.
RUN systemctl enable fcghar-network.service gha-register.service gha.service
EOF

docker build -t "$IMAGE_TAG" "$BUILD_CTX"

echo ">> exporting rootfs tarball"
ROOTFS_TAR="$BUILD_CTX/rootfs.tar"
CID=$(docker create "$IMAGE_TAG" /bin/true)
docker export "$CID" > "$ROOTFS_TAR"
docker rm "$CID" >/dev/null

echo ">> extracting kernel (firecracker x86_64 only loads uncompressed ELF)"
KERNEL_NAME=$(tar -tf "$ROOTFS_TAR" | grep -E "$KERNEL_GLOB" | head -1)
if [ -z "$KERNEL_NAME" ]; then
    echo "error: no kernel matching $KERNEL_GLOB found in rootfs" >&2
    exit 1
fi
echo "   found $KERNEL_NAME"
tar -xOf "$ROOTFS_TAR" "$KERNEL_NAME" > "$BUILD_CTX/bzImage"
./extract-vmlinux "$BUILD_CTX/bzImage" > "$KERNEL_OUT"
echo "   wrote $KERNEL_OUT ($(stat -c%s "$KERNEL_OUT") bytes ELF)"

echo ">> extracting initrd (Debian cloud kernel needs it for virtio_blk + xfs)"
INITRD_NAME=$(tar -tf "$ROOTFS_TAR" | grep -E "$INITRD_GLOB" | head -1)
if [ -z "$INITRD_NAME" ]; then
    echo "error: no initrd matching $INITRD_GLOB found in rootfs" >&2
    exit 1
fi
tar -xOf "$ROOTFS_TAR" "$INITRD_NAME" > "$INITRD_OUT"
echo "   wrote $INITRD_OUT ($(stat -c%s "$INITRD_OUT") bytes)"

echo ">> creating ${ROOT_SIZE_MB} MiB sparse XFS image at $OUT_FS"
rm -f "$OUT_FS"
truncate -s "${ROOT_SIZE_MB}M" "$OUT_FS"
mkfs.xfs -q -f "$OUT_FS"

echo ">> mounting + untarring rootfs (needs sudo)"
MNT=$(mktemp -d)
sudo mount -o loop "$OUT_FS" "$MNT"
sudo tar -xpf "$ROOTFS_TAR" -C "$MNT" \
    --xattrs --xattrs-include='*' \
    --exclude='dev/*' --exclude='proc/*' --exclude='sys/*'
# /.dockerenv would make systemd-detect-virt return "docker"; remove it.
sudo rm -f "$MNT/.dockerenv"
sudo tee "$MNT/etc/resolv.conf" > /dev/null <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

# Bake URL + TOKEN into /etc/fcghar/register.env so gha-register.service
# auto-registers on first boot. Either PROJECT=owner/repo or URL=… works.
if [ -n "${TOKEN:-}" ]; then
    if [ -z "${URL:-}" ] && [ -n "${PROJECT:-}" ]; then
        URL="https://github.com/$PROJECT"
    fi
    : "${URL:?need URL or PROJECT when TOKEN is set}"
    sudo tee "$MNT/etc/fcghar/register.env" > /dev/null <<EOF
URL=$URL
TOKEN=$TOKEN
EOF
    sudo chmod 0600 "$MNT/etc/fcghar/register.env"
    echo "   baked URL=$URL into /etc/fcghar/register.env (token elided)"
else
    echo "   no TOKEN given — register.env left empty; use 'make vm-adopt' at runtime"
fi

sudo mkdir -p "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/run"
sudo umount "$MNT"
rmdir "$MNT"

echo
echo "ok. Built:"
echo "  kernel: $KERNEL_OUT"
echo "  rootfs: $OUT_FS  ($(du -h "$OUT_FS" | cut -f1))"
echo
echo "Next: ./net-up.sh (sudo), then 'make vm-up'."
