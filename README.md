# fcghar — firecracker github actions runner

Self-hosted GitHub Actions runner inside a firecracker microVM.

## Quickstart

```sh
# DISTRO defaults to debian
PROJECT=owner/repo TOKEN=<registration-token> DISTRO=arch make oneshot
```

Token is short-lived (~1h). Grab one from:
`github.com/<owner>/<repo>/settings/actions/runners/new`, or via the API:

```sh
gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token | jq -r .token
```

`make oneshot` builds the rootfs (once — it's a generic template with no
token in it), boots a VM, and serves `URL`/`TOKEN` to the guest via
firecracker's MMDS (metadata service at `http://169.254.169.254`). A
one-shot `gha-register.service` curls the metadata on first boot, runs
`config.sh`, and touches a guard file so it never re-registers. After
that `gha.service` keeps `run.sh` alive across reboots. Re-running
`oneshot` with a new token is cheap — no docker rebuild, just another
VM boot at the next free slot.

## Multiple runners

Each `make oneshot` boots a fresh VM at the lowest free slot, so calling it
again with a new token spawns an additional runner alongside the first:

```sh
PROJECT=owner/repo TOKEN=$tok1 make oneshot   # slot 0 -> 192.168.43.10
PROJECT=owner/repo TOKEN=$tok2 make oneshot   # slot 1 -> 192.168.43.11
make vm-list                                  # who's running
SLOT=1 make ssh-runner                        # ssh into slot 1
SLOT=0 make vm-down                           # kill slot 0
make vm-down                                  # kill all
```

`net-up.sh` pre-creates `SLOTS=8` taps; raise it for more concurrent VMs.

## Customizing the rootfs

Two knobs for changing what lands in the image without forking the build:

```sh
# Skip docker-ce — useful if your workflows don't need it.
NO_DOCKER=1 make vm-rootfs

# Splice a Dockerfile fragment in (rustup, extra apt packages, static binaries).
# See dist/vm/prehook.example.dockerfile for the available patterns.
PREHOOK=dist/vm/prehook.example.dockerfile make vm-rootfs
```

The snippet is raw Dockerfile (it's spliced after the runner is downloaded
and before docker installs), so you get full `RUN` / `COPY` / `USER` /
`ENV` semantics. You own picking apt vs pacman idioms — for cross-distro
fragments, branch on `$DISTRO` inside the snippet.

## Knobs

| var              | default            | notes                                                              |
| ---------------- | ------------------ | ------------------------------------------------------------------ |
| `DISTRO`         | `debian-trixie`    | also `debian-bookworm`, `ubuntu-noble`, `ubuntu-jammy`, `arch`     |
| `VCPU`           | 4                  | applied at every `vm-run`                                          |
| `MEM_MIB`        | 4096               | applied at every `vm-run`                                          |
| `ROOT_SIZE_MB`   | 32768              | applied at every `vm-run` (xfs_growfs at boot); XFS only grows     |
| `EXTRA_PKGS`     | htop tmux duf ripgrep | extra packages installed in the VM; same names on apt + pacman  |
| `NO_DOCKER`      | (unset)            | set to `1` to skip docker-ce install (~3 min faster, ~500 MB)      |
| `PREHOOK`        | (unset)            | path to a Dockerfile snippet spliced in after runner download      |
| `SLOT`           | (auto)             | `vm-run` picks lowest free; `ssh/tail/adopt/down` default to 0/all |
| `SLOTS`          | 8                  | how many tap-runner-* taps `net-up.sh` creates                     |
| `RUNNER_VERSION` | 2.334.0            | bump together with `RUNNER_SHA256`                                 |
| `RUNNER_LABELS`  | fcghar,firecracker | passed to `config.sh --labels`                                     |

## Targets

`make help` for the full list. The notable ones:

- `make oneshot` — full rebuild + boot at next free slot + auto-register
- `make vm-up` — boot existing rootfs at next free slot (no re-register)
- `make vm-list` — show running VMs (slot, pid, ip, status)
- `make vm-ping` — ICMP-ping a slot (cheap reachability check)
- `make vm-down` — kill all VMs (or `SLOT=N make vm-down` for one)
- `make vm-tail` — follow serial console (all by default, `SLOT=N` for one)
- `make ssh-runner` — `ssh root@192.168.43.1{0+SLOT}` (default slot 0)
- `make vm-adopt` — late-bind: SSH in and register against an already-built rootfs

## Layout

```
Makefile
dist/vm/
  build-rootfs.sh         emits the per-distro Dockerfile (base + actions-runner
                          + docker engine + EXTRA_PKGS), exports the rootfs
                          tarball, extracts the kernel + initrd, mkfs.xfs's
                          /tmp/fcghar/rootfs.xfs and untars the rootfs in
  distros.sh              per-DISTRO base image, kernel package, glob, pkg mgr
  fetch-images.sh         docker pull the base image (DISTRO-aware)
  net-up.sh / net-down.sh fcghar-br0 192.168.43.0/24 + tap-runner-0..N + NAT (sudo)
  vm-run.sh               picks free SLOT, sed-substitutes IP/MAC/TAP/HOST/
                          DRIVE/VCPU/MEM into runner.json, writes per-slot
                          MMDS metadata (URL/TOKEN), boots firecracker with
                          --metadata
  adopt.sh                fallback: SSH in, run config.sh with URL+TOKEN
  configs/runner.json     firecracker config template (mmds-config + sed'd
                          per-slot values)
  extract-vmlinux         decompresses bzImage to ELF for firecracker
  overlays/               files baked into the rootfs:
    etc/systemd/system/   fcghar-network.service, fcghar-growfs.service,
                          gha-register.service, gha.service
    usr/local/bin/        fcghar-network (parses kernel cmdline, brings up
                          eth0, pins 169.254.169.254 route), gha-register
                          (curl MMDS → config.sh + touchfile guard)
```
