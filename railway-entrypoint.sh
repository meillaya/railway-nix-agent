#!/usr/bin/env bash
set -euo pipefail

AGENT="${AGENT:-omo}"
PUBLIC_PORT="${PORT:-8080}"
AGENT_USER="${AGENT_USER:-admin}"
STATE_DIR="${HOME}/.railway-agent"
PASS_FILE="${STATE_DIR}/.agent-password"

mkdir -p "$HOME" "$STATE_DIR" /workspace

if [ -n "${AGENT_PASSWORD:-}" ]; then
  PASS="$AGENT_PASSWORD"
elif [ -s "$PASS_FILE" ]; then
  PASS="$(cat "$PASS_FILE")"
else
  PASS="$(openssl rand -hex 18)"
  umask 077
  printf '%s' "$PASS" > "$PASS_FILE"
  echo "[entrypoint] no AGENT_PASSWORD set; generated one (persisted at $PASS_FILE)"
  echo "[entrypoint] username=$AGENT_USER password=$PASS"
  echo "[entrypoint] set AGENT_PASSWORD as a service variable to keep it out of the deploy log"
fi

case "$AGENT" in
  omo) INTERNAL_PORT="${INTERNAL_PORT:-7681}" ;;
  dsh) INTERNAL_PORT="${INTERNAL_PORT:-3080}" ;;
  none) INTERNAL_PORT="" ;;
  *) echo "[entrypoint] unknown AGENT=$AGENT (omo|dsh|none)"; exit 1 ;;
esac

AGENT_HASH="$(caddy hash-password --plaintext "$PASS")"
export AGENT_USER AGENT_HASH PUBLIC_PORT INTERNAL_PORT

if [ "$AGENT" = "none" ]; then
  cat > /etc/caddy/Caddyfile <<'EOF'
{
  admin off
  auto_https off
}
:{$PUBLIC_PORT} {
  handle /healthz {
    respond "ok" 200
  }
  handle {
    respond "zix base image (AGENT=none): nix + zix, no agent" 200
  }
}
EOF
else
  cat > /etc/caddy/Caddyfile <<'EOF'
{
  admin off
  auto_https off
}
:{$PUBLIC_PORT} {
  handle_path /healthz* {
    reverse_proxy 127.0.0.1:{$INTERNAL_PORT}
  }
  handle {
    basic_auth {
      {$AGENT_USER} {$AGENT_HASH}
    }
    reverse_proxy 127.0.0.1:{$INTERNAL_PORT}
  }
}
EOF
fi

AGENT_PID=""
case "$AGENT" in
  omo)
    ttyd -i 127.0.0.1 -p "$INTERNAL_PORT" -W tmux new-session -A -s agent omo &
    AGENT_PID=$!
    ;;
  dsh)
    node --expose-internals "$(command -v dsh)" web \
      --host 127.0.0.1 --port "$INTERNAL_PORT" &
    AGENT_PID=$!
    ;;
esac

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!

echo "[entrypoint] public :$PUBLIC_PORT (Caddy basic auth) -> loopback ${INTERNAL_PORT:-none} ($AGENT)"
echo "[entrypoint] packages: zix get NAME[@VERSION]  (store-path index; no nixpkgs eval)"

if [ -n "$AGENT_PID" ]; then
  wait -n "$AGENT_PID" "$CADDY_PID" || true
  echo "[entrypoint] a supervised process exited; stopping the container"
  kill "$AGENT_PID" "$CADDY_PID" 2>/dev/null || true
  wait || true
  exit 1
else
  wait "$CADDY_PID"
fi
