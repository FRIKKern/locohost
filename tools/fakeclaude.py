#!/usr/bin/env python3
# Stands in for the claude CLI in test.sh. Reads the review input on stdin, saves it for the
# redaction checks, and answers like `claude -p --output-format json --json-schema`:
# hosts listening on $LOCOHOST_TEST_IDLE_PORT are idle, every other host is in use.
# With $LOCOHOST_TEST_CLAUDE_LIMIT set it answers like an account that is out of usage.
import json, os, sys
data = sys.stdin.read()
if os.environ.get("LOCOHOST_TEST_CLAUDE_LIMIT"):
    print(json.dumps({"type": "result", "is_error": True, "result": "Claude AI usage limit reached|1793880000",
                      "total_cost_usd": 0.0, "usage": {"input_tokens": 0, "output_tokens": 0}}))
    sys.exit(1)
open(os.environ["LOCOHOST_TEST_SENT"], "w").write(data)
port = int(os.environ.get("LOCOHOST_TEST_IDLE_PORT", "0"))
hosts = [{"id": h["id"], "verdict": "idle" if port in h["ports"] else "in_use", "confidence": 0.95,
          "about": "fixture", "reason": "fixture says so", "what": "a fixture server", "how": "python http.server",
          "why": "test.sh started it", "waste": "nothing to speak of", "recommendation": "stop it when the test ends"}
         for h in json.loads(data)["hosts"]]
print(json.dumps({"type": "result", "is_error": False, "result": "", "structured_output": {"hosts": hosts},
                  "total_cost_usd": 0.0, "usage": {"input_tokens": 10, "output_tokens": 5}}))
