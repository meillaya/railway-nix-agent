#!/usr/bin/env bash
# Publish this image + repo as a Railway marketplace template.
#
# NOT run in the session that authored this repo (that run validated locally
# only, by choice). Review every step, then run it deliberately - it creates a
# public template on your workspace and a billable service project.
#
# Prerequisites:
#   railway CLI >= 5.30, logged in        (railway whoami)
#   docker or podman logged in to GHCR    (docker login ghcr.io)
#
# Usage:
#   IMAGE=ghcr.io/meillaya/railway-nix-agent:0.1.0 scripts/publish-template.sh
set -euo pipefail

IMAGE="${IMAGE:?set IMAGE=ghcr.io/meillaya/railway-nix-agent:<version>}"
TEMPLATE_NAME="${TEMPLATE_NAME:-Nix Agent Workspace}"
CATEGORY="${CATEGORY:-AI/ML}"
DESCRIPTION="${DESCRIPTION:-A coding agent with all of nixpkgs on Railway: light alpine + nix image, zix gets any package version in seconds, password-gated.}"
VOLUME_MOUNT="${VOLUME_MOUNT:-/home/agent}"

command -v railway >/dev/null || { echo "railway CLI not installed"; exit 1; }
railway whoami >/dev/null || { echo "railway login first"; exit 1; }

echo "== 1/6 push the image (skip if already pushed) =="
echo "   podman build -t $IMAGE . && podman push $IMAGE"

echo "== 2/6 create the project and service from the image =="
railway init --name "$(echo "$TEMPLATE_NAME" | tr ' ' '-')"
railway add --service agent --image "$IMAGE"

echo "== 3/6 volume + networking =="
railway volume add --mount-path "$VOLUME_MOUNT" --service agent
railway domain --service agent

echo "== 4/6 service settings =="
echo "   In the dashboard, set: healthcheck /healthz, restart ON_FAILURE,"
echo "   1 GB memory, and AGENT_PASSWORD as a generated input (the template"
echo "   editor's 'generate strong password' keeps it out of deploy logs)."

echo "== 5/6 snapshot the project into a template draft =="
TEMPLATE_JSON="$(railway templates create --json)"
echo "$TEMPLATE_JSON"
TEMPLATE_ID="$(printf '%s' "$TEMPLATE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null || true)"
[ -n "$TEMPLATE_ID" ] || { echo "could not read the template id; open the dashboard"; exit 1; }

echo "== 6/6 publish ($TEMPLATE_ID) =="
railway templates publish "$TEMPLATE_ID" \
  --category "$CATEGORY" \
  --description "$DESCRIPTION" \
  --readme-file README.md \
  --json

echo "done - the deploy page is at railway.com/deploy/<slug>"
