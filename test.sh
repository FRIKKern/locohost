#!/bin/sh
# End-to-end checks against the installed CLI, using fixtures only: Python HTTP servers on free
# ports above 47100 that this script starts itself, and tools/fakeclaude.py and tools/fakecodex.py in place of
# the claude and codex CLIs.
# State goes to a temporary LOCOHOST_HOME. No other server on the machine is touched:
# every stop is aimed at a fixture port with --port or by port number.
set -u
cd "$(dirname "$0")"
BIN="$HOME/.local/bin/locohost"
[ -x "$BIN" ] || { echo "locohost CLI not installed; run ./build.sh"; exit 1; }
export LOCOHOST_HOME="$(mktemp -d)"
export LOCOHOST_CLAUDE="$PWD/tools/fakeclaude.py" LOCOHOST_CODEX="$PWD/tools/fakecodex.py" LOCOHOST_TEST_SENT="$LOCOHOST_HOME/sent.json"
export CODEX_HOME="$LOCOHOST_HOME"   # no model list, so Luna means gpt-6-luna, then gpt-5.6-luna
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok    %-50s %s\n' "$1" "$3"; else fail=$((fail+1)); printf '  FAIL  %-50s got %s, want %s\n' "$1" "$3" "$2"; fi; }
listening() { nc -z 127.0.0.1 "$1" >/dev/null 2>&1 && echo yes || echo no; }
json() { python3 -c "import json,sys; j=json.load(sys.stdin); print($1)"; }
serve() { # port, [stubborn], [seconds to wait before starting]. Detached, so the shell reports nothing when it dies.
  ( ( sleep "${3:-0}"; cd "$LOCOHOST_HOME" && exec python3 -c "
import http.server, os, signal, sys
open(os.environ['LOCOHOST_HOME'] + '/pid-%d' % os.getpid(), 'w').close()
if sys.argv[2] == 'stubborn': signal.signal(signal.SIGTERM, signal.SIG_IGN)
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), http.server.SimpleHTTPRequestHandler).serve_forever()
" "$1" "${2:-plain}" --api-key SUPERSECRET123 DATABASE_URL=postgres://user:hunter2@db/x ) >/dev/null 2>&1 & )
}
cleanup() { for f in "$LOCOHOST_HOME"/pid-*; do [ -e "$f" ] && kill -9 "${f##*pid-}" 2>/dev/null; done; rm -rf "$LOCOHOST_HOME"; }
trap cleanup EXIT

# The fixture servers run in $LOCOHOST_HOME. Give that folder a project, a secret .env and an agent session that
# started just before them, so the review shows what is read and what is never sent.
HOMEDIR=$(cd "$LOCOHOST_HOME" && pwd -P)
printf '{"name": "fixture-app", "description": "Fixture project for LocoHost tests", "scripts": {"dev": "python3 -m http.server"}}' > "$LOCOHOST_HOME/package.json"
printf '# Fixture\n\nA small server that test.sh starts and stops.\n' > "$LOCOHOST_HOME/README.md"
printf 'API_TOKEN=ENVSECRET999\n' > "$LOCOHOST_HOME/.env"
export CLAUDE_CONFIG_DIR="$LOCOHOST_HOME/claude"
SESS="$CLAUDE_CONFIG_DIR/projects/$(printf %s "$HOMEDIR" | tr '/.' '--')"
mkdir -p "$SESS"
python3 - "$SESS/fixture.jsonl" "$HOMEDIR" <<'PY'
import json, sys, datetime
t = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"type": "user", "timestamp": t, "cwd": sys.argv[2], "message": {"role": "user", "content": "Start the fixture server, password=HUNTER77 is fine"}}) + "\n")
    f.write(json.dumps({"type": "ai-title", "aiTitle": "Fixture session", "sessionId": "fixture"}) + "\n")
PY

P=$("$BIN" free 47100)
echo "== ports (fixture port $P)"
check "free returns a port nobody listens on" no "$(listening "$P")"
"$BIN" ready "$P" --timeout 1 >/dev/null 2>&1;                   check "ready times out with exit 1" 1 "$?"
serve "$P" plain 1
"$BIN" ready "$P" --http --timeout 15 >/dev/null;                 check "ready --http waits for the server" 0 "$?"
"$BIN" who "$P" | grep -q "Python http.server";                    check "who names the framework" 0 "$?"
r=$("$BIN" list --json | json "[h['kind'] for h in j['hosts'] if $P in h['ports']][0]")
                                                                    check "list --json lists it as a dev server" dev "$r"
"$BIN" who "$P" | grep -q "SUPERSECRET123"
                                                                    check "who shows the full command locally" 0 "$?"

echo "== review and close idle"
LOCOHOST_IDLE_MINUTES=0 LOCOHOST_TEST_IDLE_PORT=$P "$BIN" review >/dev/null; check "review with the fake CLI succeeds" 0 "$?"
grep -q "SUPERSECRET123" "$LOCOHOST_TEST_SENT";                    check "the api key value is not sent" 1 "$?"
grep -q "hunter2" "$LOCOHOST_TEST_SENT";                           check "the URL password is not sent" 1 "$?"
grep -q "http.server" "$LOCOHOST_TEST_SENT";                       check "the rest of the command is sent" 0 "$?"
grep -q "fixture-app" "$LOCOHOST_TEST_SENT";                       check "the package.json name is sent" 0 "$?"
grep -q "ENVSECRET999" "$LOCOHOST_TEST_SENT";                      check ".env contents are never sent" 1 "$?"
grep -q "Fixture session" "$LOCOHOST_TEST_SENT";                   check "the agent session title is sent" 0 "$?"
grep -q "HUNTER77" "$LOCOHOST_TEST_SENT";                          check "a secret in the session prompt is redacted" 1 "$?"
"$BIN" explain "$P" | grep -q "a fixture server";                  check "explain shows the model's what" 0 "$?"
r=$("$BIN" list --json | json "sorted(k for k in [h for h in j['hosts'] if $P in h['ports']][0] if k.startswith('idle'))")
                                                                    check "list --json has the waste counters" "['idleCPUSeconds', 'idleEnergyWh']" "$r"
r=$("$BIN" waste --json | json "[h['port'] for h in j['hosts']].count($P)")
                                                                    check "waste lists the fixture" 1 "$r"
r=$("$BIN" idle --json | json "len(j['candidates'])")
                                                                    check "with a 30 min threshold nothing is idle yet" 0 "$r"
r=$(LOCOHOST_IDLE_MINUTES=0 "$BIN" idle --json --port "$P" | json "len(j['candidates'])")
                                                                    check "quiet plus an idle verdict makes a candidate" 1 "$r"
F=$(python3 -c "import json; print(json.load(open('$LOCOHOST_HOME/rules.json'))['protect']['ports'])")
python3 - "$LOCOHOST_HOME/rules.json" "$P" <<'PY'
import json,sys; p,port=sys.argv[1],int(sys.argv[2]); j=json.load(open(p)); j['protect']['ports'].append(port); json.dump(j,open(p,'w'))
PY
r=$(LOCOHOST_IDLE_MINUTES=0 "$BIN" idle --json --port "$P" | json "len(j['candidates'])")
                                                                    check "a protected port is never a candidate" 0 "$r"
python3 - "$LOCOHOST_HOME/rules.json" "$P" <<'PY'
import json,sys; p,port=sys.argv[1],int(sys.argv[2]); j=json.load(open(p)); j['protect']['ports'].remove(port); json.dump(j,open(p,'w'))
PY
LOCOHOST_IDLE_MINUTES=0 "$BIN" close-idle --yes --port "$P" >/dev/null; check "close-idle --yes stops it, exit 0" 0 "$?"
check "and the port is free" no "$(listening "$P")"
"$BIN" stopped --json | grep -q "http.server";                    check "stopped keeps its restart command" 0 "$?"

echo "== Luna when Haiku is out of usage"
serve "$P"; "$BIN" ready "$P" --timeout 10 >/dev/null
r=$(LOCOHOST_TEST_CLAUDE_LIMIT=1 OPENAI_API_KEY=sk-test "$BIN" review --model auto --json | json "j['model']")
                                                                    check "auto falls back to Luna, without the API key" gpt-6-luna "$r"
r=$(json "'usage limit' in j['note']" < "$LOCOHOST_HOME/review.json")
                                                                    check "and notes why Haiku was skipped" True "$r"
grep -q "SUPERSECRET123" "$LOCOHOST_TEST_SENT";                    check "the api key value is not sent to Luna" 1 "$?"
r=$(LOCOHOST_TEST_CODEX_UNSUPPORTED=gpt-6-luna "$BIN" review --model luna --json | json "j['model']")
                                                                    check "luna moves on from a model the account lacks" gpt-5.6-luna "$r"

echo "== modes (every auto run names the fixture port, so no other server is judged or stopped)"
export LOCOHOST_IDLE_MINUTES=0 LOCOHOST_MIN_UPTIME_MINUTES=0
plan() { "$BIN" auto --port "$P" --json "$@" | json "j['plan'][0]['stop'] if j['plan'] else 'none'"; }
LOCOHOST_TEST_IDLE_PORT=$P "$BIN" review --mode eager >/dev/null
r=$(json "j['summary']" < "$LOCOHOST_HOME/review.json");          check "the review writes a summary" "Fixture summary: $(json "j['hostCount']" < "$LOCOHOST_HOME/review.json") servers." "$r"
r=$("$BIN" auto --mode eager --port "$P" --dry-run --json | json "j['plan'][0]['why'].startswith('its agent session was active')")
                                                                    check "eager keeps a server whose agent session is active" True "$r"
export CLAUDE_CONFIG_DIR="$LOCOHOST_HOME/no-sessions"   # from here on no session, so the mode decides
r=$(plan --mode idle);                                             check "idle mode stops nothing" False "$r"
r=$(plan --mode proactive);                                        check "proactive waits for a long quiet" False "$r"
r=$(LOCOHOST_PROACTIVE_MINUTES=0 plan --mode proactive);           check "proactive stops sure idle after the wait" True "$r"
r=$("$BIN" stopped --json | json "j[0]['by']");                    check "stopped records the mode" Proactive "$r"
check "and the port is free" no "$(listening "$P")"

serve "$P"; "$BIN" ready "$P" --timeout 10 >/dev/null
LOCOHOST_TEST_UNSURE_PORT=$P LOCOHOST_TEST_KEEP_PORT=$P "$BIN" review --mode eager >/dev/null
r=$(json "any($P in h['ports'] for h in j['hosts'])" < "$LOCOHOST_HOME/sent.json.judge")
                                                                    check "eager sends an unsure server to the judge" True "$r"
r=$(plan --mode eager --dry-run);                                  check "the judge keeps it when it shows evidence" False "$r"
r=$("$BIN" auto --mode eager --port "$P" --dry-run --json | json "j['plan'][0]['why'].startswith('evidence')")
                                                                    check "and says what the evidence is" True "$r"
LOCOHOST_TEST_UNSURE_PORT=$P "$BIN" review --mode eager >/dev/null
r=$(LOCOHOST_MIN_UPTIME_MINUTES=30 plan --mode eager);             check "eager never stops a server started minutes ago" False "$r"
r=$(plan --mode eager);                                            check "eager stops it without evidence" True "$r"
check "and the port is free" no "$(listening "$P")"
r=$("$BIN" stopped --json | json "j[0]['by']");                    check "stopped records the mode" Eager "$r"
"$BIN" restart "$P" >/dev/null;                                    check "restart starts it again from its recorded command" 0 "$?"
"$BIN" ready "$P" --http --timeout 15 >/dev/null;                  check "and it answers again" 0 "$?"
LOCOHOST_TEST_IDLE_PORT=$P "$BIN" review --mode eager >/dev/null
"$BIN" keep "$P" 1 >/dev/null
r=$("$BIN" auto --mode eager --port "$P" --json | json "j['plan'][0]['why'].startswith('kept by you')")
                                                                    check "keep holds it back from eager" True "$r"
"$BIN" keep "$P" 0 >/dev/null
r=$(plan --mode eager --dry-run);                                  check "and releasing it hands it back to the mode" True "$r"
unset LOCOHOST_IDLE_MINUTES LOCOHOST_MIN_UPTIME_MINUTES

echo "== where a server runs"
TMUX_BIN=$(command -v tmux || true)
if [ -n "$TMUX_BIN" ]; then
  W=$("$BIN" free $((P + 1)))
  "$TMUX_BIN" new-session -d -s "locohost-test-$$" -n fixture "cd '$LOCOHOST_HOME' && exec python3 -m http.server $W --bind 127.0.0.1"
  "$BIN" ready "$W" --timeout 10 >/dev/null
  r=$("$BIN" where "$W" --json | json "j.get('kind','none')")
  "$TMUX_BIN" kill-session -t "locohost-test-$$" 2>/dev/null
  check "where names the tmux pane a server runs in" tmux "$r"
else
  echo "  skip  tmux is not installed"
fi

echo "== a failed review closes nothing"
LOCOHOST_TEST_CLAUDE_LIMIT=1 LOCOHOST_CODEX=/usr/bin/false "$BIN" review --model auto >/dev/null 2>&1
                                                                    check "both models failing exits 1" 1 "$?"
LOCOHOST_CLAUDE=/usr/bin/false "$BIN" review --model haiku >/dev/null 2>&1; check "review reports failure with exit 1" 1 "$?"
r=$(LOCOHOST_IDLE_MINUTES=0 "$BIN" idle --json --port "$P" | json "len(j['candidates'])")
                                                                    check "and nothing is a candidate" 0 "$r"
"$BIN" close "$P" --yes >/dev/null;                                check "close <port> --yes stops one server" 0 "$?"

echo "== a server that ignores SIGTERM"
serve "$P" stubborn; "$BIN" ready "$P" --timeout 10 >/dev/null
"$BIN" close "$P" --yes >/dev/null; rc=$?;                         check "close leaves it running, exit 3" 3 "$rc"
check "still listening" yes "$(listening "$P")"
"$BIN" close "$P" --yes --force >/dev/null;                        check "close --force kills it, exit 0" 0 "$?"
check "and the port is free" no "$(listening "$P")"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
