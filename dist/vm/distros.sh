# Sourced by build-rootfs.sh and fetch-images.sh.
# Sets BASE / KERNEL_PKG / KERNEL_GLOB / INITRD_GLOB / PKG_MGR / SSHD_SVC
# based on $DISTRO. PKG_MGR = "apt" | "pacman" picks the Dockerfile dialect.

distro_setup() {
    case "${DISTRO:-debian-trixie}" in
        debian-trixie)
            BASE="debian:trixie"
            KERNEL_PKG="linux-image-cloud-amd64"
            KERNEL_GLOB='^boot/vmlinuz-[0-9].*-cloud-amd64$'
            INITRD_GLOB='^boot/initrd\.img-[0-9].*-cloud-amd64$'
            PKG_MGR="apt"
            SSHD_SVC="ssh.service"
            ;;
        debian-bookworm)
            BASE="debian:bookworm"
            KERNEL_PKG="linux-image-cloud-amd64"
            KERNEL_GLOB='^boot/vmlinuz-[0-9].*-cloud-amd64$'
            INITRD_GLOB='^boot/initrd\.img-[0-9].*-cloud-amd64$'
            PKG_MGR="apt"
            SSHD_SVC="ssh.service"
            ;;
        ubuntu-noble)
            BASE="ubuntu:noble"
            KERNEL_PKG="linux-image-virtual"
            KERNEL_GLOB='^boot/vmlinuz-[0-9].*-generic$'
            INITRD_GLOB='^boot/initrd\.img-[0-9].*-generic$'
            PKG_MGR="apt"
            SSHD_SVC="ssh.service"
            ;;
        ubuntu-jammy)
            BASE="ubuntu:jammy"
            KERNEL_PKG="linux-image-virtual"
            KERNEL_GLOB='^boot/vmlinuz-[0-9].*-generic$'
            INITRD_GLOB='^boot/initrd\.img-[0-9].*-generic$'
            PKG_MGR="apt"
            SSHD_SVC="ssh.service"
            ;;
        arch)
            BASE="archlinux:latest"
            KERNEL_PKG="linux"
            KERNEL_GLOB='^boot/vmlinuz-linux$'
            INITRD_GLOB='^boot/initramfs-linux\.img$'
            PKG_MGR="pacman"
            SSHD_SVC="sshd.service"
            ;;
        *)
            echo "error: unknown DISTRO '${DISTRO}'" >&2
            echo "supported: debian-trixie debian-bookworm ubuntu-noble ubuntu-jammy arch" >&2
            return 2
            ;;
    esac
}
