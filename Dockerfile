# The lightest Railway-ready agent image with nix package acquisition.
#
# Shape (mirrors what the reference deepseek-harness image does right, and
# changes what it does heavy):
#
#   internet --> Caddy on 0.0.0.0:$PORT   (basic auth; /healthz open)
#                  |
#                  '--> agent on 127.0.0.1 (ttyd+omo by default, never public)
#
# Why this base: alpine + apk's nix is ~44 MiB of image, against ~235 MiB for
# debian-slim + the official installer and ~562 MiB for nixos/nix. The store
# paths it installs are self-contained, so glibc nixpkgs binaries (node,
# ripgrep, anything the agent pulls) run fine on the musl userland.
#
# Why the proxy: omo/dsh have no authentication of their own. An agent with a
# shell tool on an open URL is remote code execution on the deployer's
# Railway account. Nothing here patches that; the agent stays on loopback and
# Caddy owns the only public surface.
#
# Package acquisition: `zix get NAME[@VERSION]` installs through
# nixpkgs-multiverse's store-path index - no nixpkgs evaluation, so an exact
# version installs in seconds at a few hundred MB of peak RAM instead of the
# ~600 MB+ eval spike. That is what makes a small Railway plan and a light
# image sufficient.
FROM alpine:3.21

ARG AGENT=omo
ARG OMO_VERSION=5.1.22

ENV NIX_CONFIG="experimental-features = nix-command flakes" \
    HOME=/home/agent \
    PATH=/home/agent/.nix-profile/bin:/root/.nix-profile/bin:/opt/npm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# One apk layer with the whole runtime userland. `build-users-group =` is the
# well-known container fix: without it every nix operation tries to use the
# nixbld build users, which do not exist here.
RUN apk add --no-cache \
      bash \
      caddy \
      ca-certificates \
      nix \
      openssl \
      python3 \
      tini \
      ttyd \
 && mkdir -p /etc/nix /home/agent /workspace \
 && printf 'build-users-group =\n' > /etc/nix/nix.conf \
 && command -v nix caddy ttyd tini

# The zix CLI (runtime package acquisition). Vendored from the machine0/
# nixos config repos; stdlib Python only.
COPY vendor/zix /opt/zix
RUN printf '#!/bin/sh\nexec python3 /opt/zix/cli.py "$@"\n' > /usr/local/bin/zix \
 && chmod 0755 /usr/local/bin/zix \
 && zix --version

# The agent. omo-ai requires node >= 24; alpine ships node 22, so node comes
# from nixpkgs (glibc store path, runs on musl as any substituted package
# does). The npm tree is what the image ships: the release is not a
# self-contained bundle, the engine needs its own node_modules at runtime.
RUN set -eux; \
    case "$AGENT" in \
      omo|dsh) nix profile install --profile /root/.nix-profile nixpkgs#nodejs_24 ;; \
      none) : ;; \
      *) echo "unknown AGENT=$AGENT (omo|dsh|none)"; exit 1 ;; \
    esac; \
    if [ "$AGENT" = "dsh" ]; then apk add --no-cache --virtual .dsh-build build-base; fi; \
    export PATH="/root/.nix-profile/bin:$PATH"; \
    case "$AGENT" in \
      omo) \
        node --version; \
        npm install -g --prefix /opt/npm "omo-ai@${OMO_VERSION}"; \
        /opt/npm/bin/omo --version ;; \
      dsh) \
        node --version; \
        npm install -g --prefix /opt/npm @deepseek-ai/dsh ;; \
      none) : ;; \
    esac; \
    if [ "$AGENT" = "dsh" ]; then apk del .dsh-build; fi; \
    nix store gc || true; \
    rm -rf /root/.cache /root/.npm /home/agent/.npm

# Serve the base image's own story on the root when no agent is installed.
RUN printf 'no agent in this image (AGENT=none): nix + zix only\\n' > /workspace/README.txt

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod 0755 /usr/local/bin/railway-entrypoint.sh

ENV AGENT=${AGENT}

EXPOSE 8080

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/railway-entrypoint.sh"]
