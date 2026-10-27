# CLI

The app's binary is also a command line tool, at `~/.local/bin/locohost`. It does not need the menu bar app to run, and it shares `activity.json` and `review.json` with it.

```sh
locohost list                    # every localhost, with state and who started it
locohost list --json             # the same for agents, plus the ignored listeners and Close Idle candidates
locohost who 3000                # who holds :3000, its folder, branch, command and clients
locohost explain 3000            # what it is, how it runs, why it is there, what it wastes, with the evidence
locohost where 3000              # the cmux tab, tmux pane, terminal tab or app it runs in; --go brings it forward
locohost waste                   # every server ranked by CPU, energy and memory since it was last used
locohost ready 3000 --http       # wait until :3000 answers HTTP; exit 0 ready, 1 timed out (--timeout 60)
locohost free 3000               # the first free port at or above 3000
locohost review                  # ask the model now; in Eager the judge looks again; --model luna or --model sonnet to pick one
locohost summary                 # the last summary, and what the mode would stop and keep, with reasons
locohost auto --dry-run          # one round of the mode without stopping; drop --dry-run to stop; --review reviews first
locohost mode eager              # show or set the mode: idle, proactive or eager
locohost idle                    # what Close Idle would stop right now
locohost close-idle --yes        # stop them; --force SIGKILLs the ones that ignore SIGTERM; --review reviews first
locohost close 4100 --yes        # stop one server by port or pid
locohost stopped                 # what was stopped, by whom and why, with the command that starts each again
locohost restart 3317            # start the server last stopped on :3317 again
locohost keep 3317 8             # no mode stops it for 8 hours; 0 releases it
locohost open 3000
```

Exit codes: 0 done, 1 not found, aborted or timed out, 2 usage, 3 some servers still running.

## For agents

An agent starting a dev server in a worktree:

```sh
PORT=$(locohost free 3000)
pnpm dev --port "$PORT" &
locohost ready "$PORT" --http --timeout 90 && echo "http://localhost:$PORT"
```

`locohost who <port>` explains a port conflict. `--mode` and `--port` work with `summary` and `auto`. Ask the user before `locohost close-idle --yes` or `locohost auto`, and never stop a server another agent started without saying so.

## URL scheme

The app answers `open locohost://review`, `locohost://close-idle` with a confirmation, `locohost://login-on`, `locohost://login-off` and `locohost://quit`.

## Settings

| Key in `no.guerrilla.locohost` | Default | Meaning |
|---|---|---|
| `locohost.reviewMinutes` | 60 | Minutes between reviews, 0 off |
| `locohost.mode` | `eager` | `idle` reports only, `proactive` stops obvious waste, `eager` stops what can't show evidence |
| `locohost.model` | `auto` | `auto` is Haiku, then Luna. Also `haiku`, `sonnet`, `opus`, `luna` or any model name |
| `locohost.idleMinutes` | 30 | Quiet this long counts as idle |
| `locohost.probeHTTP` | true | Read page titles |
| `locohost.askBeforeClosing` | true | Confirm Close Idle |
| `locohost.forceMode` | 1 | A server that ignores SIGTERM: 0 leave, 1 ask, 2 force |
| `locohost.claudePath`, `locohost.codexPath` | found | Where the CLIs are |
