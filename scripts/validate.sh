#!/usr/bin/env bash
# Local validation for the railway-nix-agent image. Usage:
#   scripts/validate.sh <image> [container-name] [host-port]
#
# Runs the image the way Railway does (PORT injected, 1 GB cap) and checks the
# release conditions: the auth gate, the open healthcheck, loopback-only agent
# binding, and the runtime package acquisition path (fast + pinned version).
set -uo pipefail

IMG="${1:?usage: validate.sh <image> [name] [host-port]}"
NAME="${2:-ulw-railway-agent}"
HP="${3:-28080}"
B="http://127.0.0.1:${HP}"
PASS=0
FAIL=0

chk() {
  if [ "$2" = "$3" ]; then
    printf '  PASS  %-56s %s\n' "$1" "$3"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %-56s expected=%s got=%s\n' "$1" "$2" "$3"
    FAIL=$((FAIL + 1))
  fi
}
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }
now() { date +%s; }

echo "=== $IMG ==="
podman rm -f "$NAME" >/dev/null 2>&1 || true
mkdir -p /tmp/ulw-railway-vol
podman run -d --name "$NAME" --memory 1g --memory-swap 1g --cpus 2 \
  -p "${HP}:8080" -e PORT=8080 -e AGENT_PASSWORD=testpw123 \
  -v /tmp/ulw-railway-vol:/home/agent "$IMG" >/dev/null

for _ in $(seq 1 40); do
  [ "$(code "$B/healthz")" = "200" ] && break
  sleep 3
done

echo "  container: $(podman inspect "$NAME" --format 'status={{.State.Status}} oom={{.State.OOMKilled}}')"
echo "  memory:    $(podman stats --no-stream --format '{{.MemUsage}}' "$NAME" 2>/dev/null)"
echo "  image:     $(podman images --format '{{.Size}}' "$IMG" | head -1)"

echo "-- auth gate (the release condition) --"
chk "unauthenticated GET /" 401 "$(code "$B/")"
chk "unauthenticated GET /token" 401 "$(code "$B/token")"
chk "wrong password" 401 "$(code -u admin:wrongpw "$B/")"
chk "empty password" 401 "$(code -u admin: "$B/")"
chk "forged loopback Host header" 401 "$(code -H 'Host: 127.0.0.1:7681' "$B/")"
chk "healthcheck path, unauthenticated" 200 "$(code "$B/healthz")"
chk "authenticated GET /" 200 "$(code -u admin:testpw123 "$B/")"

echo "-- agent must not be reachable off loopback --"
BIND_PUBLIC=$(podman exec "$NAME" sh -c "awk '\$2 ~ /:1F90\$/ && \$4 == \"0A\" {c++} END {print c+0}' /proc/net/tcp6 2>/dev/null" | tr -d '[:space:]')
BIND_LOOP=$(podman exec "$NAME" sh -c "awk '\$2 ~ /:1E01\$/ && \$4 == \"0A\" {c++} END {print c+0}' /proc/net/tcp 2>/dev/null" | tr -d '[:space:]')
chk "public 8080 listening (published port)" "yes" "$([ "${BIND_PUBLIC:-0}" -ge 1 ] && echo yes || echo no)"
chk "agent 7681 bound on 127.0.0.1" "yes" "$([ "${BIND_LOOP:-0}" -ge 1 ] && echo yes || echo no)"

echo "-- runtime package acquisition (zix) --"
t0=$(now); podman exec "$NAME" zix get ripgrep >/tmp/ulw-railway-get-rg.log 2>&1; rc=$?; t1=$(now)
chk "zix get ripgrep (latest, fast road)" 0 "$rc"
echo "        elapsed: $((t1 - t0))s"
t0=$(now); podman exec "$NAME" zix get hello@2.10 >/tmp/ulw-railway-get-hello.log 2>&1; rc=$?; t1=$(now)
chk "zix get hello@2.10 (pinned, fast road)" 0 "$rc"
echo "        elapsed: $((t1 - t0))s"
chk "exact version runs" "hello (GNU Hello) 2.10" \
  "$(podman exec "$NAME" /home/agent/.nix-profile/bin/hello --version 2>/dev/null | head -1)"
t0=$(now); podman exec "$NAME" zix get jq >/tmp/ulw-railway-get-jq.log 2>&1; rc=$?; t1=$(now)
chk "zix get jq (warm)" 0 "$rc"
echo "        elapsed: $((t1 - t0))s"
chk "zix get --list" 0 "$(podman exec "$NAME" zix get --list >/dev/null 2>&1; echo $?)"
chk "zix get hello@2.10 is idempotent" 0 "$(podman exec "$NAME" zix get hello@2.10 >/dev/null 2>&1; echo $?)"
echo "        memory.peak: $(podman exec "$NAME" cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo NA) bytes"

echo "-- summary: ${PASS} pass / ${FAIL} fail --"
[ "$FAIL" -eq 0 ]
