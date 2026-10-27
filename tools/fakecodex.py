#!/usr/bin/env python3
# Stands in for the codex CLI in test.sh. Answers like `codex exec --json --output-schema --output-last-message`
# with tools/fakeanswer.py. It fails when a tool is
# left on, when an API key reaches it, or when the model is in $LOCOHOST_TEST_CODEX_UNSUPPORTED.
import json, os, sys
args = sys.argv[1:]
def fail(msg):
    print(json.dumps({"type": "turn.failed", "error": {"message": json.dumps({"type": "error", "status": 400, "error": {"message": msg}})}}))
    sys.exit(1)
need = ["--sandbox read-only", "--ignore-user-config", "--ephemeral"] + ["--disable " + f for f in ("shell_tool", "unified_exec", "apps", "plugins", "multi_agent")]
joined = " ".join(args)
for n in need:
    if n not in joined: fail("fixture: missing " + n)
if "OPENAI_API_KEY" in os.environ: fail("fixture: an API key reached codex")
model = args[args.index("--model") + 1]
if model in os.environ.get("LOCOHOST_TEST_CODEX_UNSUPPORTED", "").split(","):
    fail("The '%s' model is not supported when using Codex with a ChatGPT account." % model)
data = sys.stdin.read()
import fakeanswer
so = fakeanswer.answer(data, open(args[args.index("--output-schema") + 1]).read())
open(args[args.index("--output-last-message") + 1], "w").write(json.dumps(so))
print(json.dumps({"type": "thread.started", "thread_id": "fixture"}))
print(json.dumps({"type": "turn.completed", "usage": {"input_tokens": 20, "cached_input_tokens": 0, "output_tokens": 7}}))
