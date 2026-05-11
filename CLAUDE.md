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
- The image bakes in: actions-runner, docker engine + buildx + compose
  (gha is in the `docker` group), openssh-server, and `$EXTRA_PKGS`
  (default `htop tmux duf ripgrep`). Same package names work on
  apt + pacman; for distro-specific names, edit the per-branch list.
- Two opt-in customization knobs handled in `build-rootfs.sh`:
  `NO_DOCKER=1` skips the docker-ce install entirely (~3 min, ~500 MB),
  and `PREHOOK=<path>` cat's a raw Dockerfile fragment into the build
  right after the runner download (before docker). The PREHOOK splice
  point is part of the contract — moving it would silently break user
  snippets. Example at `dist/vm/prehook.example.dockerfile`.

## Registration model

- Token is **served via MMDS**, not baked into the rootfs. `vm-run.sh`
  writes a per-slot JSON (`/tmp/fcghar/runner-N.mmds.json`) shaped
  `{"fcghar": {"url": "...", "token": "..."}}` and starts firecracker
  with `--metadata path/to/that.json`. Firecracker serves it at
  `http://169.254.169.254/fcghar`.
- The rootfs (`/tmp/fcghar/rootfs.xfs`) is **generic** — no URL/TOKEN in
  it. Build it once with `make vm-rootfs`; re-running `oneshot` with a
  new token reuses the template (no docker rebuild).
- `fcghar-network` adds a `169.254.169.254/32 dev eth0` route so the curl
  in `gha-register` finds MMDS without going via the default gw.
- `gha-register.service` is a oneshot guarded by
  `ConditionPathExists=!/etc/fcghar/.registered`. On first boot it curls
  `/fcghar`, parses url/token with `jq`, runs `config.sh --unattended`,
  and touches the guard. On failure (no MMDS, empty payload) it touches
  the guard anyway so we don't loop.
- `gha.service` has `Requires=gha-register.service` and
  `ConditionPathExists=/home/gha/runner/.runner` so it can't start an
  unregistered runner into a `Restart=always` loop.
- `adopt.sh` is the late-bind escape hatch: boot a VM without TOKEN, then
  `URL=… TOKEN=… [SLOT=N] make vm-adopt` to register over SSH.
- **Tokens are single-use.** One token per VM. The single-use property is
  unrelated to MMDS — it's GitHub's API behavior. Calling `oneshot` twice
  with the same token will succeed on the first slot and fail on the
  second.

## MMDS specifics

- V1 (no session-token PUT dance). Configured via `mmds-config.version`
  in `configs/runner.json`. We don't have a guest-side HTTP server that
  could be SSRF'd, so V2's protection buys us nothing.
- `mmds-config.network_interfaces: ["eth0"]` is what grants the iface
  access; the per-NIC `allow_mmds_requests` field is deprecated.
- `--metadata <file>` is the `--no-api`-mode equivalent of `PATCH /mmds`
  on the API socket. Loaded at firecracker start, before the guest kernel
  jumps to userspace.
- `firecracker` watches dst-IP 169.254.169.254 on the tap and responds
  inline; the kernel still needs to ARP for it, which is why
  `fcghar-network` adds the /32 route via eth0.

## Disk auto-grow

- `mkfs.xfs` runs at build time at `ROOT_SIZE_MB` (default 32 GB). The
  file is sparse; bytes only land on host disk as the guest writes them.
- `vm-run.sh` `truncate`s the per-slot drive up to `ROOT_SIZE_MB` if it's
  smaller than that, so bumping the env between boots grows the disk
  without a rootfs rebuild. We never shrink (XFS can't anyway).
- `fcghar-growfs.service` runs `xfs_growfs /` before `basic.target` on
  every boot — idempotent, no-op once the FS already fills the device.
  Gated by `ConditionPathExists=/usr/sbin/xfs_growfs` so it silently
  skips if `xfsprogs` is ever dropped.

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
