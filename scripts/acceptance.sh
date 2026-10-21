#!/usr/bin/env bash
# Hook acceptance checks from docs/design.md. Uses a throwaway AGENT_STATUS_DIR,
# never touches ~/.claude. Usage: scripts/acceptance.sh [path/to/agent-status-hook]
set -euo pipefail

HOOK="${1:-$(cd "$(dirname "$0")/.." && pwd)/build/bin/agent-status-hook}"
[[ -x "$HOOK" ]] || { echo "hook binary not found: $HOOK" >&2; exit 1; }

export AGENT_STATUS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentbar-accept.XXXXXX")"
trap 'rm -rf "$AGENT_STATUS_DIR"' EXIT
FILE="$AGENT_STATUS_DIR/acc1.json"
fails=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# feed <event json>: runs the hook, checks exit 0 and empty stdout
feed() {
  local out code
  out="$(printf '%s' "$1" | "$HOOK")" && code=0 || code=$?
  [[ $code -eq 0 ]] || fail "exit code $code for: $1"
  [[ -z "$out" ]] || fail "stdout not empty for: $1"
}

# field <name>: prints a field of the status file
field() { python3 -c "import json;v=json.load(open('$FILE'))['$1'];print(str(v).lower() if isinstance(v,bool) else v)"; }

expect() { # expect <label> <state> <unread> <detail>
  local s u d
  s="$(field state)"; u="$(field unread)"; d="$(field detail)"
  if [[ "$s" == "$2" && "$u" == "$3" && "$d" == "$4" ]]; then pass "$1 -> $s/$u/'$d'"
  else fail "$1: got $s/$u/'$d', want $2/$3/'$4'"; fi
}

base='"session_id":"acc1","cwd":"/tmp/demo-proj"'
echo "1. event sequence"
feed "{$base,\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}";            expect SessionStart idle false ""
feed "{$base,\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"fix\\nthe bug\"}"; expect UserPromptSubmit busy false "fix the bug"
feed "{$base,\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\"}";             expect PreToolUse busy false "Bash"
feed "{$base,\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\"}";            expect PostToolUse busy false "Bash"
feed "{$base,\"hook_event_name\":\"Stop\"}";                                           expect Stop replied true ""
feed "{$base,\"hook_event_name\":\"Notification\",\"message\":\"waiting for input\"}"; expect "Notification(after Stop)" replied true ""
[[ "$(field project)" == "demo-proj" ]] && pass "project = demo-proj" || fail "project"
feed "{$base,\"hook_event_name\":\"SessionEnd\",\"reason\":\"exit\"}"
[[ ! -e "$FILE" ]] && pass "SessionEnd deletes file" || fail "file still exists after SessionEnd"

echo "2. bad input"
for input in '' 'not json' '[1]' '{"session_id":"../../evil","hook_event_name":"Stop"}' \
             '{"session_id":"a/b","hook_event_name":"Stop"}' '{"hook_event_name":"Stop"}'; do
  feed "$input"
done
n="$(find "$AGENT_STATUS_DIR" -name '*.json' | wc -l | tr -d ' ')"
[[ "$n" == 0 ]] && pass "no files written for bad input" || fail "$n files written for bad input"
[[ ! -e "$AGENT_STATUS_DIR/../evil.json" ]] && pass "no path traversal" || fail "path traversal"

echo "3. 50 concurrent writers"
for i in $(seq 1 50); do
  printf '{"session_id":"conc","cwd":"/tmp/c","hook_event_name":"PreToolUse","tool_name":"T%s"}' "$i" | "$HOOK" &
done
wait
if python3 -c "import json;json.load(open('$AGENT_STATUS_DIR/conc.json'))" 2>/dev/null; then pass "file is valid JSON"; else fail "conc.json invalid"; fi
tmpleft="$(find "$AGENT_STATUS_DIR" -name '*.tmp' | wc -l | tr -d ' ')"
[[ "$tmpleft" == 0 ]] && pass "no .tmp leftovers" || fail "$tmpleft .tmp files left"

echo "4. interop with the Python prototype's file format"
python3 - "$AGENT_STATUS_DIR/py1.json" <<'EOF'
import json, sys, time
# What status_hook.py writes: json.dump defaults (ensure_ascii=True), float times.
json.dump({"v": 1, "session_id": "py1", "project": "项目", "cwd": "/tmp/项目", "state": "waiting",
           "detail": "需要确认", "unread": True, "since": time.time(), "updated": time.time(),
           "py_only": {"x": 1}}, open(sys.argv[1], "w"))
EOF
BAR="$(dirname "$HOOK")/agent-bar"
if [[ -x "$BAR" ]]; then
  "$BAR" --list | grep -q '项目 .*等你确认' && pass "agent-bar reads a Python-written file" || fail "agent-bar --list cannot read py1.json"
fi
printf '{"session_id":"py1","cwd":"/tmp/项目","hook_event_name":"PreToolUse","tool_name":"Edit"}' | "$HOOK"
python3 - "$AGENT_STATUS_DIR/py1.json" <<'EOF' && pass "Python reads the C++-updated file, unknown field kept" || fail "py1.json after C++ update"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["state"] == "busy" and d["detail"] == "Edit" and d["project"] == "项目" and d["py_only"] == {"x": 1}
EOF

echo "5. emit (adapter CLI for other agents)"
"$HOOK" emit --session-id emit1 --event UserPromptSubmit --cwd /tmp/other-agent --prompt "hello there" &&
  "$HOOK" emit --session-id emit1 --event Stop
FILE="$AGENT_STATUS_DIR/emit1.json"
expect "emit Stop" replied true ""
[[ "$(field project)" == "other-agent" ]] && pass "emit keeps cwd/project" || fail "emit project"
"$HOOK" emit --session-id ../x --event Stop 2>/dev/null && fail "emit accepted a bad id" || pass "emit rejects a bad id"
"$HOOK" emit --session-id emit1 --event Bogus 2>/dev/null && fail "emit accepted an unknown event" || pass "emit rejects an unknown event"
"$HOOK" emit --session-id emit1 --event SessionEnd
[[ ! -e "$FILE" ]] && pass "emit SessionEnd deletes" || fail "emit SessionEnd"

echo "6. speed"
payload="$AGENT_STATUS_DIR/payload.json"
printf '{"session_id":"perf","cwd":"/tmp/p","hook_event_name":"PreToolUse","tool_name":"Bash"}' > "$payload"
if command -v hyperfine >/dev/null; then
  hyperfine -N --warmup 20 --runs 300 --input "$payload" --export-json "$AGENT_STATUS_DIR/hf.json" "$HOOK" >/dev/null 2>&1
  # hyperfine 1.x exports results[].median; 2.x exports per-run measurements.
  med_ms="$(python3 - "$AGENT_STATUS_DIR/hf.json" <<'EOF'
import json, statistics, sys
r = json.load(open(sys.argv[1]))['results'][0]
if 'median' in r:
    m = r['median']
else:
    m = statistics.median(x['time_wall_clock']['value'] for x in r['measurements'])
print('%.2f' % (m * 1000))
EOF
)"
  tool=hyperfine
else
  med_ms="$(python3 - "$HOOK" "$payload" <<'EOF'
import subprocess, sys, time, statistics
hook, payload = sys.argv[1], sys.argv[2]
ts = []
for _ in range(300):
    with open(payload, 'rb') as f:
        t = time.perf_counter(); subprocess.run([hook], stdin=f); ts.append(time.perf_counter() - t)
print('%.2f' % (statistics.median(ts) * 1000))
EOF
)"
  tool="python subprocess (includes fork overhead)"
fi
python3 -c "import sys;sys.exit(0 if float('$med_ms')<5 else 1)" && pass "median ${med_ms} ms < 5 ms ($tool)" || fail "median ${med_ms} ms >= 5 ms ($tool)"

echo
if [[ $fails -eq 0 ]]; then echo "all acceptance checks passed"; else echo "$fails check(s) failed"; exit 1; fi
