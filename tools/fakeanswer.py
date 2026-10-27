# The answers tools/fakeclaude.py and tools/fakecodex.py give, from the review input on stdin.
# Review: hosts on $LOCOHOST_TEST_IDLE_PORT are idle, on $LOCOHOST_TEST_UNSURE_PORT unsure, every other host in use.
# Judge (the Eager second pass, recognised by its schema): the host on $LOCOHOST_TEST_KEEP_PORT is kept with
# evidence, every other host is stopped. The judge's input is saved to $LOCOHOST_TEST_SENT.judge.
import json, os

def port(name):
    return int(os.environ.get(name, "0"))

def answer(data, schema):
    hosts = json.loads(data)["hosts"]
    if '"decision"' in schema:
        open(os.environ["LOCOHOST_TEST_SENT"] + ".judge", "w").write(data)
        keep = port("LOCOHOST_TEST_KEEP_PORT")
        return {"hosts": [{"id": h["id"], "decision": "keep" if keep in h["ports"] else "stop", "confidence": 0.9,
                           "evidence": "fixture: a test client still uses it" if keep in h["ports"] else "",
                           "reason": "the fixture judge says so"} for h in hosts]}
    open(os.environ["LOCOHOST_TEST_SENT"], "w").write(data)
    idle, unsure = port("LOCOHOST_TEST_IDLE_PORT"), port("LOCOHOST_TEST_UNSURE_PORT")
    def verdict(h):
        return "idle" if idle in h["ports"] else "unsure" if unsure in h["ports"] else "in_use"
    return {"summary": "Fixture summary: %d servers." % len(hosts),
            "hosts": [{"id": h["id"], "verdict": verdict(h), "confidence": 0.5 if verdict(h) == "unsure" else 0.95,
                       "about": "fixture", "reason": "fixture says so", "what": "a fixture server", "how": "python http.server",
                       "why": "test.sh started it", "waste": "nothing to speak of", "recommendation": "stop it when the test ends",
                       "keep_evidence": ""} for h in hosts]}
