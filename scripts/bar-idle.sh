#!/usr/bin/env bash
# Idle resource check for agent-bar: runs it for N seconds (default 3600) on a
# throwaway status dir with a few sessions and reports average CPU and memory.
#   scripts/bar-idle.sh [seconds] [build/bin]
set -euo pipefail
SECS="${1:-3600}"
BIN="${2:-$(cd "$(dirname "$0")/.." && pwd)/build/bin}"
export AGENT_STATUS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentbar-idle.XXXXXX")"
for i in 1 2 3; do
  printf '{"session_id":"idle%s","cwd":"/tmp/p%s","hook_event_name":"PreToolUse","tool_name":"Bash"}' "$i" "$i" | "$BIN/agent-status-hook"
done
"$BIN/agent-bar" &
PID=$!
trap 'kill $PID 2>/dev/null || true; rm -rf "$AGENT_STATUS_DIR"' EXIT
sleep 5
cpu_secs() { ps -o time= -p "$PID" | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
footprint_mb() { footprint "$PID" 2>/dev/null | awk '/Footprint:/{v=$(NF-5); u=$(NF-4); if (u=="KB") v/=1024; if (u=="GB") v*=1024; print v; exit}'; }
c0="$(cpu_secs)"
samples=()
left="$SECS"
while [[ $left -gt 0 ]]; do
  step=$(( left < 60 ? left : 60 )); sleep "$step"; left=$((left - step))
  samples+=("$(footprint_mb)")
done
c1="$(cpu_secs)"
python3 - "$SECS" "$c0" "$c1" "${samples[@]}" <<'PY'
import sys, statistics
secs, c0, c1 = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
fp = [float(x) for x in sys.argv[4:] if x]
print("idle %ds: CPU %.4f%% average (%.2fs cpu)" % (secs, (c1 - c0) / secs * 100, c1 - c0))
if fp:
    print("footprint MB: median %.1f, min %.1f, max %.1f, last %.1f (%d samples)" % (statistics.median(fp), min(fp), max(fp), fp[-1], len(fp)))
PY
