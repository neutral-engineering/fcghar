# Example PREHOOK. Spliced into the rootfs Dockerfile after the actions-runner
# is downloaded, before docker-ce installs. The fragment is raw Dockerfile —
# you pick the package manager, you own conditional logic on $DISTRO.
#
# Use it via:
#   PREHOOK=dist/vm/prehook.example.dockerfile make vm-rootfs
#
# Common patterns below; delete what you don't want.

# ---- extra apt packages (Debian/Ubuntu) ----
# RUN apt-get update \
#     && apt-get install -y --no-install-recommends \
#         build-essential pkg-config libssl-dev \
#     && apt-get clean && rm -rf /var/lib/apt/lists/*

# ---- rustup as the gha user, into /home/gha/.cargo ----
USER gha
WORKDIR /home/gha
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal \
    && /home/gha/.cargo/bin/rustup component add clippy rustfmt
ENV PATH="/home/gha/.cargo/bin:${PATH}"
USER root

# ---- a single static binary fetched from a release ----
# RUN curl -fsSL -o /usr/local/bin/example \
#         https://example.com/releases/v1.0/example-linux-x64 \
#     && chmod 0755 /usr/local/bin/example
