# railway-nix-agent

A coding agent with all of nixpkgs on Railway - in the lightest image that can
honestly carry it. The agent runs on loopback behind Caddy basic auth; a
password gate that cannot be switched off; `/healthz` open for the platform
prober; and `zix get NAME[@VERSION]` inside the container installs any package
version nixpkgs ever shipped in seconds, without evaluating nixpkgs.

This is the "what could we do better" answer to
[deepseek-harness-on-nixos](https://railway.com/deploy/deepseek-harness-on-nixos-just-updated-agent-with-all-of-nixpkgs--deepseek-harness-on-nixos-or-just-update)
(the reference keeps the agent itself; this project changes the base, the
acquisition path, and the healthcheck honesty).

## What is in the image

| piece | choice | why |
| --- | --- | --- |
| base | `alpine:3.21` + `apk add nix` | ~114 MiB of installed packages vs ~154 MiB for the reference's nixos/nix base and ~562 MiB for the published reference image. Store paths are self-contained, so glibc nixpkgs binaries (node, ripgrep, anything the agent pulls) run on the musl userland. |
| package CLI | `zix get NAME[@VERSION]` (vendored in `vendor/zix`) | installs through nixpkgs-multiverse's store-path index: no nixpkgs evaluation, seconds instead of tens of seconds, a few hundred MB of peak RAM instead of the ~600 MB-1 GB eval spike. |
| agent | omo-ai 5.1.22 by default (`AGENT=dsh` and `AGENT=none` build args exist) | node 24 comes from nixpkgs (alpine ships 22); the agent's own npm tree, pinned. |
| surface | `ttyd` + `tmux` on 127.0.0.1:7681, proxied by Caddy on `$PORT` | closing the browser tab detaches instead of killing a running task. |
| auth | Caddy basic auth; password required, generated and persisted if not supplied | an agent with a shell tool on an open URL is remote code execution on the deployer's account. The agent is never reachable off loopback. |
| health | `/healthz` proxied to the agent port | a static 200 answers even when the agent is dead; the proxy fails the deploy instead. |

## Local build and validation

```bash
podman build -t railway-nix-agent:omo .                 # or --build-arg AGENT=dsh|none
bash scripts/validate.sh railway-nix-agent:omo           # run it like Railway does
```

`scripts/validate.sh` runs the image under a 1 GB cap with `PORT` injected and
checks the release conditions: five unauthenticated 401s (including a forged
loopback `Host` header), `/healthz` 200, authenticated 200, loopback-only
binding, and `zix get` for a latest package, a pinned version, and a warm
install - with the container's `memory.peak` reported at the end.

Measured on 2026-10-07 (alpine:3.21 base, AGENT=omo):

| metric | value |
| --- | --- |
| image (uncompressed on disk) | 1.04 GB |
| image (compressed, gzip proxy for pull weight) | 394 MiB (reference: 588.7 MB across 76 layers) |
| idle RSS after boot | 37.5 MB |
| `zix get ripgrep` (latest, cold container) | 5 s |
| `zix get hello@2.10` (exact 2016 version) | 1 s |
| `zix get jq` (warm) | 2 s |
| container `memory.peak` across boot + all three installs | 303 MiB (final run; 398 MiB on a re-run - cgroup v2 counts page cache) |
| auth gate | 401 unauthenticated / 401 wrong password / 401 forged Host / 200 with credentials |
| loopback-only agent / published port listening | confirmed via /proc/net/tcp{,6} |
| node inside | 24.21.0 (nixpkgs, on musl) |
| omo inside | 5.1.22 (engine senpi 2026.10.10-5) |
| validation suite | 15 pass / 0 fail (`scripts/validate.sh`) |

The fast path peaked at 303 MiB in the final validation run and 398 MiB on a
re-run (cgroup v2 counts page cache; treat 300-400 MiB as the band), so 512 MB
is a bench observation with headroom risk. The declared floor stays 1 GB
because the evaluating fallback (`--eval-road`, or an attr the index does not
carry) evaluates nixpkgs and spikes well past 512 MB.

## Runtime packages (what the agent runs)

```bash
zix get ripgrep              # latest, store-path index
zix get hello@2.10           # any version that ever shipped
zix get --list               # what the profile holds
zix get --eval-road cmatrix  # force the evaluating road (heavier)
```

Installs land in the invoking user's nix profile (`~/.nix-profile`, on the
volume) and the store path in the image layer. After a redeploy the profile
entry survives but its store path does not - re-running the same `get` repairs
it in seconds. Do NOT mount a volume at `/nix`: it shadows the baked store and
the container stops booting.

## Environment variables

| variable | default | purpose |
| --- | --- | --- |
| `PORT` | 8080 | Railway injects it; the public port. |
| `AGENT_PASSWORD` | generated | basic-auth password. Generated once and persisted at `$HOME/.railway-agent/.agent-password` when unset; printed once to the deploy log. |
| `AGENT_USER` | `admin` | basic-auth user. |
| `AGENT` | build-time arg | `omo`, `dsh`, or `none`. |
| `INTERNAL_PORT` | 7681 (omo) / 3080 (dsh) | the loopback port the agent owns. |

Mount a volume at `/home/agent` for the workspace, agent config, and the
generated password. Everything else (including `/nix`) is the image.

## Publishing it as a Railway template

An image-source template needs no repository files - the template manifest is
the config. `scripts/publish-template.sh` walks the CLI flow
(`railway init` -> `add --image` -> `volume add` -> `templates create` ->
`templates publish`); two steps are dashboard-only and called out in the
script: the generated `AGENT_PASSWORD` input and the healthcheck path.

Note: Railway's Config-as-Code (`railway.json`/`railway.toml`) stops being read
on 2026-12-01 for existing files and new services cannot opt in - the
`railway.json` in this repo is kept for repo-sourced deploys but the manifest
is the future-proof surface. `template/manifest.example.json` shows the shape
the platform generates.

## How this claims to be better, and how to falsify it

| axis | this image | reference | status |
| --- | --- | --- | --- |
| base image content | 44.2 MiB of apk packages | 154 MB measured base | measured |
| pull weight | 394 MiB compressed | 588.7 MB compressed across 76 layers | measured |
| package install | 1-5 s fast path, 303 MiB container peak | 16-20 s eval road, 784 MB peak | measured |
| idle RSS | 37.5 MB (`podman stats --no-stream`) | 135 MiB claimed, method unstated | measured here; the reference figure is not directly comparable |
| auth matrix | 401 on /, /token, wrong+empty password, forged Host; 200 with credentials | same posture, their own verify suite | measured |
| healthcheck | proxied to the agent port | static 200 from the proxy | measured locally; Railway only checks deploy-time |

Not measured in the authoring session (do these before publishing): deploy-to-healthz
seconds on a real Railway plan; redeploy durability (disclaimed in Runtime packages
above: the store path does not survive, re-running `get` repairs it in seconds); rebuild
reproducibility digest; failure injection (the entrypoint supervises with `wait -n` and
exits 1 when either process dies, which is the intended behaviour but has not been
exercised as a test).

## Limits and honest caveats

- The `dsh` flavor compiles `node-pty` at install and pulls a ~4 GiB closure
  upstream; the Dockerfile path exists but was not built or validated in the
  session that authored this repo.
- `bun` (>= 1.4) is omo's own preferred runtime and would save ~150 MB over
  node; the pinned nixpkgs here ships bun 1.3.3, so node 24 is what the image
  validated. A bun flavor is a recorded next step.
- zix's own `sandbox`/`vm` commands need `/dev/fuse` + `SYS_ADMIN` / `/dev/kvm`
  and cannot run on Railway service containers; use `nix shell`/`zix get`
  inside the container instead. Railway Sandboxes (their VM primitive) is the
  escape hatch if real isolation is needed.
- alpine:3.21 carries nix 2.23.3; alpine 3.22/3.24 carry 2.31.x (newer
  `nix profile add`). zix probes `add` -> `install` so both work; moving the
  base up is a recorded follow-up, not a requirement.
