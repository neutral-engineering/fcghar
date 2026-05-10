# Claude notes for fcghar

Read this once before touching `dist/vm/`. It captures decisions and gotchas
that are not derivable from the code alone.

## Shape of the project

- One firecracker microVM per GitHub Actions runner. `make oneshot` boots
  at the **lowest free slot** (auto-detected by scanning
  `/tmp/fcghar/runner-*.pid`), so calling it again with a new token spawns
  an additional runner alongside the first. To replace a slot, use
  `SLOT=N make vm-down` then `make oneshot`.
- Per-slot derivations are mechanical: IP `192.168.43.$((10 + SLOT))`,
  MAC `AA:FC:00:00:43:$(printf %02X $((0x0A + SLOT)))`, tap `tap-runner-N`,
  host `fcghar-runner-N`, files `/tmp/fcghar/runner-N.{xfs,pid,log,config.json}`.
  The bridge is shared. `net-up.sh` pre-creates `SLOTS=8` taps.
- `dist/vm/` layout was lifted from `../dblk-rs/dist/vm/` and trimmed
  (single bridge, no shim binaries, no dual-plane network). Don't be
  surprised if the patterns rhyme.
- The rootfs is built inside Docker (`docker build` + `docker export`),
  then untarred onto a fresh XFS image. `extract-vmlinux` pulls the ELF
  kernel out of the distro's bzImage.

## Registration model

- Token is **baked into the image** at `/etc/fcghar/register.env` (mode
  0600), written by `build-rootfs.sh` after the loop-mount step.
- `gha-register.service` is a oneshot guarded by
  `ConditionPathExists=!/etc/fcghar/.registered`. On first boot it sources
  `register.env`, runs `config.sh --unattended`, and touches the guard.
- `gha.service` has `Requires=gha-register.service` and
  `ConditionPathExists=/home/gha/runner/.runner` so it can't start an
  unregistered runner into a `Restart=always` loop.
- `adopt.sh` is the late-bind escape hatch: build a tokenless rootfs, then
  `URL=… TOKEN=… [SLOT=N] make vm-adopt` to register over SSH.
- **Tokens are single-use.** Each `oneshot` rebuilds the template with the
  given token; the new VM's runner-N.xfs is a copy at boot time. Calling
  `oneshot` twice with the *same* token will fail registration on the
  second VM. One token per VM.

## Distro support

`distros.sh` is the source of truth — adding a distro means adding one row
plus possibly a new branch in `build-rootfs.sh`. The current matrix:

- `debian-trixie` (default), `debian-bookworm` — apt, `linux-image-cloud-amd64`
- `ubuntu-noble`, `ubuntu-jammy` — apt, `linux-image-virtual` (`-generic` glob)
- `arch` — pacman, `linux`, separate Dockerfile branch

Apt-distros let the runner's own `bin/installdependencies.sh` install
libicu/libssl. **Do not pin those manually** — the version tracks the base
image and pinning breaks cross-distro use.

### Arch-specific gotchas (each one has bitten us)

- `installdependencies.sh` doesn't speak pacman → install the runner's
  runtime deps (`icu openssl krb5 zlib lttng-ust`) in the Dockerfile.
- `mkinitcpio` defaults include `autodetect`, which strips out modules not
  loaded on the build host — i.e. `virtio_blk`. Override
  `MODULES=(virtio virtio_blk virtio_net virtio_pci xfs)` and remove
  `autodetect` from `HOOKS`, then `mkinitcpio -P`.
- `systemd-networkd.service` is enabled by default and races
  `fcghar-network.service` for eth0. Mask it.
- `systemd-firstboot.service` grabs the serial console and asks for
  timezone/locale. Mask it; pre-set `/etc/locale.conf` and `/etc/localtime`.
- The `inetutils` package isn't in base, so `hostname` (the binary) is
  missing. See next section.

## fcghar-network constraints

- Runs **before** `basic.target` (`DefaultDependencies=no`), so dbus is not
  up. That rules out `hostnamectl`. It also rules out anything that
  needs `/run/dbus/system_bus_socket`.
- The `hostname` binary is absent on Arch (in `inetutils`). Write to
  `/etc/hostname` + `/proc/sys/kernel/hostname` directly. Same applies to
  `gha-register` and `adopt.sh` — use `$HOSTNAME` (bash) or read
  `/etc/hostname` rather than calling `hostname`.
- Look up the network interface by virtio_net driver, not by name —
  `net.ifnames=0` is set in the boot args but don't trust it absolutely;
  `find_iface` falls back to scanning `/sys/class/net/*/device/driver`.

## Dev loop

For overlay scripts (`/usr/local/bin/fcghar-network`,
`/usr/local/bin/gha-register`), iterate without rebuilding the rootfs:

```sh
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    dist/vm/overlays/usr/local/bin/<script> root@192.168.43.10:/usr/local/bin/<script>
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@192.168.43.10 \
    'systemctl reset-failed <unit> && systemctl start <unit> && systemctl status <unit>'
```

For Dockerfile / package-list / initramfs changes, you have to rebuild:
`make vm-down && PROJECT=… TOKEN=… make oneshot`. The slow step is
`docker build` (a few minutes per distro the first time, cached after).

## Diagnostics

- Serial log: `/tmp/fcghar/runner.log` (`make vm-tail`).
- Inside the VM: `journalctl -u fcghar-network -u gha-register -u gha`.
- Network not up: usually `fcghar-network` failed before assigning the IP.
  The script logs every input it parsed (cmdline keys, chosen iface) before
  acting, so `journalctl -u fcghar-network` should be self-explanatory.
- If the VM boots but ssh hangs, suspect `fcghar-network` and check the
  serial log — sshd has nowhere to bind without an IP.

## Don't

- Don't enable `gha.service` to start without `.runner` present — it'll
  spin under `Restart=always`. The `ConditionPathExists` is load-bearing.
- Don't add backwards-compat shims for older runner versions; bump
  `RUNNER_VERSION` + `RUNNER_SHA256` together as a pair.
- Don't reach for `hostname`, `hostnamectl`, `ifconfig`, `netstat`, or
  similar in early-boot scripts. Anything you depend on must be in the
  base image of every supported distro.
- Don't pull `cache/` directories into the build context — they're not
  used here (`fetch-images.sh` stays minimal).
