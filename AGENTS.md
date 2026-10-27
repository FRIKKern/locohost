# For AI agents working in this repo

**Build and verify**

```sh
./build.sh                       # universal build, installs ~/Applications/LocoHost.app and ~/.local/bin/locohost
locohost list                    # non-destructive: every localhost and its state
./test.sh                        # fixtures only: Python servers on ports from 47100 and tools/fakeclaude.py
```

**Layout**: `Sources/Ports.m` samples processes and sockets through libproc, builds one `LHHost` per listening process, detects framework, git, launcher and clients, keeps the activity history in `activity.json` and runs the HTTP title probe. `Sources/Rules.m` holds the protect and ignore lists in `rules.json`. `Sources/Intel.m` investigates each dev server: the allowlisted project files, git state, and the agent session that was open when it started, cached for five minutes. `Sources/Review.m` builds the redacted facts, runs the claude CLI, or the codex CLI for Luna, and saves `review.json`. `Sources/main.m` holds the idle decision (`Candidates`), stopping, the CLI (`RunCLI`) and the menu bar UI. `tools/mkicon.m` renders the icon. `tools/fakeclaude.py` and `tools/fakecodex.py` stand in for the two CLIs in tests.

**Invariants that must hold after any change**

1. `Candidates` is the only way to Close Idle, and it requires all of these: kind `dev`, not protected, state `LHIdle` by local signals, an `idle` verdict with confidence of at least `kMinConfidence` from a review without an error, and no activity after that review. The menu, `locohost idle` and `locohost close-idle` all use it.
2. Close Idle re-samples right before stopping. What it stops is what the confirmation listed.
3. SIGTERM first. SIGKILL only when the user's setting or an explicit `--force` allows it. Every force path says what is lost.
4. Never signal a reused pid: `+[LHScanner alive:]` checks the start time before every signal. Never signal pid 1 or LocoHost itself. Wrappers above a server are signalled; shells and agents above it are not.
5. Ignored listeners, those owned by macOS or by a running app outside `devApps`, are informational only and never reach a stop function.
6. The review sends only `+[LHReviewer factsFor:]`. From the project folders, only these are read and sent: the package.json name, description and matching script, the first README heading and paragraph, the mix.exs app name and description, the pyproject.toml name and description, and the names of framework config files. From git: the last commit subject, age and author, the number of uncommitted files, the upstream state and the count of commits not in the default branch. From agent session logs: the agent name, the session title, the first prompt, and when it started and was last active. Every text value goes through `LHRedact` and is capped at 300 characters; session text at 200; command lines at 400. `.env` files, other file contents, environment variables, page bodies and the session log path are never sent. A session in a parent folder counts only when its log named the server's folder in the half hour before the server started.
7. The review runs on the user's own login. For claude, `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` are removed from the child environment and tools are disabled with `--tools ""`. For codex, `OPENAI_API_KEY` and `CODEX_*` except `CODEX_HOME` are removed, the sandbox is read-only, the user config is ignored and every tool feature is disabled. `tools/fakecodex.py` fails the test when one of those flags is missing. The working directory is the support folder for both.
8. LocoHost's own probe is not activity. The connections of every LocoHost process, the app and any CLI run, are excluded, and new connections and CPU are ignored for `kProbeQuiet` seconds after it.
9. Builds with clang alone. No Swift, no packages, no Xcode project.

**Test hooks**: `LOCOHOST_HOME` moves every state file, `LOCOHOST_CLAUDE` and `LOCOHOST_CODEX` replace the two CLIs, and `LOCOHOST_IDLE_MINUTES` overrides the quiet threshold. Tests never stop a server they did not start: every stop names a fixture port.

**Using LocoHost from an agent**: `locohost free 3000` before starting a server, then `locohost ready <port> --http` to wait for it. `locohost who <port>` explains a port conflict. `locohost list --json` shows what else is running. Ask the user before `locohost close-idle --yes`, and never stop a server another agent started without saying so.
