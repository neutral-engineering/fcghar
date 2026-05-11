# fcghar — firecracker github actions runner.
# Run `make` with no args for a list of targets.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

SSH_OPTS := -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR

# Override on the make command line. Disk + DISTRO only take effect on rootfs
# (re)build; cpu/mem are applied at every vm-run.
DISTRO        ?= debian-trixie
VCPU          ?= 4
MEM_MIB       ?= 4096
ROOT_SIZE_MB  ?= 32768
EXTRA_PKGS    ?= htop tmux duf ripgrep

# Customization knobs for build-rootfs.sh:
# - NO_DOCKER=1     skip the docker-ce install (~3 min faster, ~500 MB smaller)
# - PREHOOK=<path>  splice a raw Dockerfile snippet into the build, right
#                   after the runner is downloaded. See prehook.example.dockerfile.
NO_DOCKER     ?=
PREHOOK       ?=

# vm-run.sh auto-picks the lowest free slot if SLOT is unset. ssh-runner /
# vm-tail / vm-adopt / vm-down default to slot 0; pass SLOT=N to target a
# specific VM. SLOTS sets how many tap-runner-* taps net-up.sh creates.
SLOTS         ?= 8

export DISTRO VCPU MEM_MIB ROOT_SIZE_MB SLOTS EXTRA_PKGS NO_DOCKER PREHOOK

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ---------- vm runtime (firecracker) ----------

.PHONY: vm-images vm-rootfs vm-net-up vm-net-down vm-run vm-up vm-down \
        vm-tail vm-list vm-ping vm-adopt oneshot ssh-runner

vm-images: ## Pull base docker image used by build-rootfs.sh (DISTRO=debian-trixie|debian-bookworm|ubuntu-noble|ubuntu-jammy|arch)
	dist/vm/fetch-images.sh

vm-rootfs: ## Build /tmp/fcghar/rootfs.xfs + kernel (generic template; URL/TOKEN come from MMDS at boot)
	dist/vm/build-rootfs.sh

vm-net-up: ## Bring up fcghar-br0 + N taps + NAT (sudo); SLOTS=N for tap count
	dist/vm/net-up.sh

vm-net-down: ## Tear down fcghar-br0 + all taps + NAT (sudo)
	dist/vm/net-down.sh

vm-run: ## Boot a VM in foreground at the next free SLOT — Ctrl-C to stop
	SLOT="$$SLOT" PROJECT="$$PROJECT" URL="$$URL" TOKEN="$$TOKEN" dist/vm/vm-run.sh

vm-up: ## Boot a VM in background at the next free SLOT (builds rootfs/network as needed)
	@[ -f /tmp/fcghar/rootfs.xfs ] || dist/vm/build-rootfs.sh
	@ip link show fcghar-br0 >/dev/null 2>&1 || dist/vm/net-up.sh
	@SLOT="$$SLOT" PROJECT="$$PROJECT" URL="$$URL" TOKEN="$$TOKEN" dist/vm/vm-run.sh --background
	@echo
	@echo "VM booting. 'SLOT=N make ssh-runner' to log in (default 0)."
	@echo "Pass PROJECT=… TOKEN=… on the make line and the runner auto-registers via MMDS."
	@echo "Without a token, use 'SLOT=N make vm-adopt' to SSH-register after the fact."

vm-down: ## Kill VMs (SLOT=N for one slot, default: all running)
	@if [ -n "$$SLOT" ]; then \
	  pidfiles="/tmp/fcghar/runner-$$SLOT.pid"; \
	else \
	  pidfiles=$$(ls /tmp/fcghar/runner-*.pid 2>/dev/null); \
	fi; \
	for pidfile in $$pidfiles; do \
	  [ -f "$$pidfile" ] || continue; \
	  pid=$$(cat "$$pidfile"); \
	  if kill -0 "$$pid" 2>/dev/null; then \
	    echo "killing $$pidfile (pid $$pid)"; kill "$$pid"; \
	  fi; \
	  rm -f "$$pidfile"; \
	done

vm-tail: ## Follow VM serial log (SLOT=N for one slot, default: all)
	@if [ -n "$$SLOT" ]; then \
	  tail -F /tmp/fcghar/runner-$$SLOT.log; \
	else \
	  tail -F /tmp/fcghar/runner-*.log; \
	fi

vm-list: ## List running VMs (slot, pid, ip)
	@printf "%-6s %-8s %-16s %s\n" SLOT PID IP STATUS; \
	shopt -s nullglob; \
	for pidfile in /tmp/fcghar/runner-*.pid; do \
	  slot=$$(basename "$$pidfile" .pid | sed 's/^runner-//'); \
	  pid=$$(cat "$$pidfile"); \
	  ip="192.168.43.$$((10 + slot))"; \
	  if kill -0 "$$pid" 2>/dev/null; then status=alive; else status="dead (stale pidfile)"; fi; \
	  printf "%-6s %-8s %-16s %s\n" "$$slot" "$$pid" "$$ip" "$$status"; \
	done

vm-ping: ## ICMP ping a runner VM (SLOT=N, default 0)
	@slot=$${SLOT:-0}; ip="192.168.43.$$((10 + slot))"; \
	 echo ">> ping slot=$$slot ip=$$ip"; \
	 ping -c 1 -W 2 "$$ip"

vm-adopt: ## SSH-register an already-built VM: PROJECT=owner/repo TOKEN=<token> [SLOT=N]
	@if [ -z "$$PROJECT$$URL" ] || [ -z "$$TOKEN" ]; then \
	  echo "usage: PROJECT=owner/repo TOKEN=<token> [SLOT=N] make vm-adopt"; exit 2; \
	fi
	SLOT="$$SLOT" PROJECT="$$PROJECT" URL="$$URL" TOKEN="$$TOKEN" dist/vm/adopt.sh

oneshot: ## End-to-end: PROJECT=owner/repo TOKEN=<token> make oneshot (builds rootfs if missing, boots next free slot, MMDS-registers)
	@if [ -z "$$PROJECT" ] || [ -z "$$TOKEN" ]; then \
	  echo "usage: PROJECT=owner/repo TOKEN=<token> make oneshot"; exit 2; \
	fi
	@docker image inspect debian:trixie >/dev/null 2>&1 || dist/vm/fetch-images.sh
	@[ -f /tmp/fcghar/rootfs.xfs ] || dist/vm/build-rootfs.sh
	@ip link show fcghar-br0 >/dev/null 2>&1 || dist/vm/net-up.sh
	PROJECT="$$PROJECT" TOKEN="$$TOKEN" dist/vm/vm-run.sh --background
	@echo
	@echo "VM booting. URL+TOKEN served via MMDS; gha-register.service curls it on first boot."
	@echo "Tail with '[SLOT=N] make vm-tail', ssh with '[SLOT=N] make ssh-runner'."

ssh-runner: ## ssh into a runner VM (SLOT=N, default 0)
	@slot=$${SLOT:-0}; ssh $(SSH_OPTS) root@192.168.43.$$((10 + slot))
