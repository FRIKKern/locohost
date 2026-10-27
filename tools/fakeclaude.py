#!/usr/bin/env python3
# Stands in for the claude CLI in test.sh. Reads the review input on stdin, saves it for the
# redaction checks, and answers like `claude -p --output-format json --json-schema` with tools/fakeanswer.py.
# With $LOCOHOST_TEST_CLAUDE_LIMIT set it answers like an account that is out of usage.
import json, os, sys
data = sys.stdin.read()
if os.environ.get("LOCOHOST_TEST_CLAUDE_LIMIT"):
    print(json.dumps({"type": "result", "is_error": True, "result": "Claude AI usage limit reached|1793880000",
                      "total_cost_usd": 0.0, "usage": {"input_tokens": 0, "output_tokens": 0}}))
    sys.exit(1)
import fakeanswer
so = fakeanswer.answer(data, sys.argv[sys.argv.index("--json-schema") + 1])
print(json.dumps({"type": "result", "is_error": False, "result": "", "structured_output": so,
                  "total_cost_usd": 0.0, "usage": {"input_tokens": 10, "output_tokens": 5}}))
