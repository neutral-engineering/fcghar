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

## Knobs

| var              | default            | notes                                                              |
| ---------------- | ------------------ | ------------------------------------------------------------------ |
| `DISTRO`         | `debian-trixie`    | also `debian-bookworm`, `ubuntu-noble`, `ubuntu-jammy`, `arch`     |
| `VCPU`           | 4                  | applied at every `vm-run`                                          |
| `MEM_MIB`        | 4096               | applied at every `vm-run`                                          |
| `ROOT_SIZE_MB`   | 10240              | only on rootfs (re)build                                           |
| `SLOT`           | (auto)             | `vm-run` picks lowest free; `ssh/tail/adopt/down` default to 0/all |
| `SLOTS`          | 8                  | how many tap-runner-* taps `net-up.sh` creates                     |
| `RUNNER_VERSION` | 2.334.0            | bump together with `RUNNER_SHA256`                                 |
| `RUNNER_LABELS`  | fcghar,firecracker | passed to `config.sh --labels`                                     |

## Targets

`make help` for the full list. The notable ones:

- `make oneshot` — full rebuild + boot at next free slot + auto-register
- `make vm-up` — boot existing rootfs at next free slot (no re-register)
- `make vm-list` — show running VMs (slot, pid, ip, status)
- `make vm-down` — kill all VMs (or `SLOT=N make vm-down` for one)
- `make vm-tail` — follow serial console (all by default, `SLOT=N` for one)
- `make ssh-runner` — `ssh root@192.168.43.1{0+SLOT}` (default slot 0)
- `make vm-adopt` — late-bind: SSH in and register against an already-built rootfs

## Layout

```
Makefile
dist/vm/
  build-rootfs.sh         emits the per-distro Dockerfile, exports the rootfs
                          tarball, extracts the kernel + initrd, mkfs.xfs's
                          /tmp/fcghar/rootfs.xfs, optionally writes
                          /etc/fcghar/register.env into the mounted image
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
    etc/systemd/system/   fcghar-network.service, gha-register.service,
                          gha.service
    usr/local/bin/        fcghar-network (parses kernel cmdline, brings up
                          eth0, pins 169.254.169.254 route), gha-register
                          (curl MMDS → config.sh + touchfile guard)
```
