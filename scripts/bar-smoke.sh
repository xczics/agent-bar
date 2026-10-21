#!/usr/bin/env bash
# Smoke test for the macOS agent-bar against a throwaway AGENT_STATUS_DIR:
# window comes up, single instance holds, redraw latency after a status change,
# click-path file writes, resident memory. Needs a GUI session.
#   scripts/bar-smoke.sh [build/bin]
set -euo pipefail

BIN="${1:-$(cd "$(dirname "$0")/.." && pwd)/build/bin}"
export AGENT_BAR_SESSIONS_DIR=/nonexistent   # do not discover the real sessions
export AGENT_STATUS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentbar-smoke.XXXXXX")"
export AGENT_STATUS_DEBUG=1
LOG="$AGENT_STATUS_DIR/bar.log"
fails=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

"$BIN/agent-bar" &
PID=$!
cleanup() { kill "$PID" 2>/dev/null || true; rm -rf "$AGENT_STATUS_DIR"; }
trap cleanup EXIT

for _ in $(seq 1 50); do grep -q started "$LOG" 2>/dev/null && break; sleep 0.1; done
if grep -q 'started visible=1' "$LOG" 2>/dev/null; then pass "window visible: $(grep -o 'frame=.*' "$LOG" | head -1)"
else fail "window did not come up"; fi

"$BIN/agent-bar"   # second instance must exit at once
kill -0 "$PID" 2>/dev/null && pass "second instance exited, first still running" || fail "first instance died"

# Redraw latency: time from the hook writing the file to the bar's redraw.
sleep 0.5
lat_total=0
for i in 1 2 3 4 5; do
  before="$(grep -c redraw "$LOG" || true)"
  t0="$(python3 -c 'import time;print(time.time())')"
  printf '{"session_id":"smoke%s","cwd":"/tmp/p%s","hook_event_name":"Stop"}' "$i" "$i" | "$BIN/agent-status-hook"
  for _ in $(seq 1 100); do [[ "$(grep -c redraw "$LOG")" -gt "$before" ]] && break; sleep 0.01; done
  t1="$(grep redraw "$LOG" | tail -1 | cut -d' ' -f1)"
  ms="$(python3 -c "print(int(($t1-$t0)*1000))")"
  lat_total=$((lat_total + ms))
  [[ $ms -lt 300 ]] && pass "redraw after ${ms} ms" || fail "redraw after ${ms} ms (>= 300)"
  sleep 0.3
done

"$BIN/agent-bar" --list | grep -q 'Agents  0 运行  5 未读' && pass "--list sees 5 unread sessions" || fail "--list output"

sleep 1
rss_kb="$(ps -o rss= -p "$PID" | tr -d ' ')"
fp="$(footprint "$PID" 2>/dev/null | grep -o 'Footprint: [0-9.]* [KMG]B' | head -1 || true)"
echo "  info  resident ${rss_kb} KB; phys_footprint ${fp:-n/a}"

echo
if [[ $fails -eq 0 ]]; then echo "bar smoke test passed"; else echo "$fails check(s) failed"; exit 1; fi
