# How LocoHost works

Every five seconds LocoHost reads the process table and every TCP socket owned by your user through `libproc`. It runs no shell commands for this, and it needs no special permissions. Each process that holds a listening port becomes one localhost, with its whole process tree rolled up.

## What it reads for each localhost

- **The process tree.** That is the server and everything below it. CPU is summed over the tree, and memory is the physical footprint.
- **Where it runs.** The working directory, then the git repo, the branch and the linked worktree. These come from reading `.git`, `HEAD` and the index modification time on a background queue.
- **What it is.** Vite, Next.js, Phoenix, Django, Postgres and about forty others, matched from the command line.
- **Who started it.** Package manager wrappers such as `pnpm dev`, an agent above it (Claude Code, Codex, OpenCode and others), the terminal app, and whether the parent is gone. A server whose parent exited was adopted by launchd after its terminal or agent finished. That is the most common leftover.
- **Who is connected.** Every established connection to its ports, named by the client app. Google Chrome counts as itself. A command line client such as `chrome-headless-shell` from Playwright counts as itself, not as the terminal it runs in.
- **Its page.** Every five minutes LocoHost sends `GET /` to each dev server to read the page title. *Read Page Titles* in the menu turns this off. LocoHost ignores connections from every LocoHost process, the app and the CLI, and the CPU spike that follows a probe.

## Investigation

For each dev server LocoHost gathers more evidence on a background queue, cached for five minutes. Services such as Postgres are skipped.

- **The project.** The `package.json` name, description and the script that matches the running command. The first heading and paragraph of the README. The app in `mix.exs`, the name and description in `pyproject.toml`. Which framework config files exist, by name only. LocoHost never opens `.env` files or any file outside this list.
- **Git.** The last commit subject, its age and author, the number of uncommitted files, ahead and behind the upstream, whether the remote branch was deleted or never pushed, and how many commits are not in the default branch.
- **The agent session.** LocoHost looks in the Claude Code, Codex and pi session logs on your Mac for the session that was open when the server started. A session counts when it ran in the server's folder. A session in a parent folder counts only if its log named the server's folder in the 30 minutes before the server started. Otherwise the answer is "no agent session found".
- **Waste.** The kernel's energy counter and CPU time for the whole process tree, recorded at each activity. That gives CPU time, Wh and memory held since the server was last used. Two dev servers on the same folder and branch are flagged as duplicates. On a Mac without the energy counter, energy shows as unknown.

`locohost explain <port>` prints this evidence with the model's five sentences. `locohost waste` ranks every server by what it burns unused.

## Where it runs

Every 30 seconds LocoHost finds the terminal or app each server runs in, in the background:

- **cmux.** `cmux top --all --processes` lists every process under its window, workspace and tab. cmux tracks its processes itself, so a server whose shell has exited is still found in its tab.
- **tmux.** `tmux list-panes -a` gives each pane's shell, matched against the server's parents. When the tmux client runs in a cmux tab, Go to opens that tab first.
- **Terminal and iTerm2.** The terminal device of the nearest shell above the server, matched against each tab's device through AppleScript. macOS asks once for permission when you first choose Go to.
- **Anything else,** such as Ghostty, Warp, VS Code, Cursor or the Claude and ChatGPT apps: the app macOS holds responsible for the process. That link survives the parent exiting. Go to brings the app forward; it cannot pick a tab or a conversation.

When the tab that started a server has closed, LocoHost says so. That alone often answers whether anyone still needs it. `locohost where <port>` prints the place, and `--go` brings it forward.

## Activity

Activity means a new connection since the last sample, or CPU well above the server's own lifetime average for two samples in a row.

A connection that stays open is not activity. That covers a browser tab with a live-reload socket that nobody has looked at in hours. A spinning BEAM scheduler is not activity either.

The history lives in `activity.json`, so a restart of LocoHost does not reset it. A server LocoHost has only just started watching counts as quiet only after a full threshold of watching.

## The states

| Marker | Meaning |
|---|---|
| ● | A new connection or real CPU work in the last sample. |
| ◐ | Active within the quiet threshold, 30 minutes by default. |
| ○ | Quiet for the threshold or longer. |
| ◇ | Quiet, and the latest review agrees it is idle. |

## When the review runs

On a schedule, hourly by default, set under *Review Every*. With the app running, these events also wake a review, at most once every ten minutes:

- A dev server LocoHost has not seen before, once it has run for two minutes. Servers that were running when LocoHost started do not count.
- A dev server that passes a day, three days or a week of uptime.
- Memory pressure reported by macOS, warning or critical.
- A one-minute load average above the number of cores for six samples in a row, half a minute.

The review records what woke it. The menu shows it next to the last review, as "woken by new server :3317 Vite".

## Modes

After each review the mode decides what to stop. *Mode* in the menu, or `locohost mode <name>`, sets it.

Every mode keeps a dev server when any of these holds: it is protected, you kept it with *Keep for 4 Hours* or `locohost keep`, it was used within the quiet threshold, it started less than 30 minutes ago, there is no review from the last three hours without an error, it was used after the review, or the agent session that started it was active in the last hour.

- **Idle** stops nothing. It reviews, summarizes and shows what Close Idle would stop.
- **Proactive** also keeps a server with a live agent process above it. It stops a server quiet for six hours that the review calls idle with at least 80% confidence.
- **Eager** stops a server the review calls idle with at least 80% confidence. Every other quiet server goes to the judge, a second model pass with the burden of proof on the server. The judge keeps a server only when it names a concrete fact that someone still needs it, and stops it otherwise with at least 60% confidence. If the judge fails, Eager stops only what the first pass called idle with at least 60% confidence.

Before stopping, LocoHost samples again, so a server used during the review stays. A mode sends SIGTERM and never asks. A server that ignores it stays running, unless *When a Server Won't Stop* is set to Force Stop It. A notification lists what was stopped. *Recently Stopped* and `locohost stopped` show who stopped each server and why.

`locohost summary` and `locohost auto --dry-run` show what the mode would do without stopping anything.

## Close Idle

Close Idle is the manual button, and it works in every mode. A server is stopped by Close Idle only when all of these hold:

1. It is a dev server, not a service such as Postgres, Redis or epmd.
2. It is not protected by name, port or folder in `rules.json`.
3. LocoHost saw no new connection and no real CPU work for the quiet threshold.
4. The latest review that did not fail called it idle with at least 60% confidence.
5. Nothing happened after that review.

Close Idle samples again right before it stops anything. What it stops is what the confirmation listed.

## Stopping

Every server gets SIGTERM and six seconds to stop. The package manager wrapper above it gets the signal too, when the server is its only child. Shells and agents above it are never signalled.

What happens to a server that refuses is your setting under *When a Server Won't Stop*: ask me, force stop it, or leave it running. Before every signal, LocoHost checks the process start time, so a reused pid is never signalled.

*Recently Stopped* lists each stopped server with who stopped it and why. *Restart* runs its recorded command again through a login shell, and `locohost restart <port>` does the same. Output goes to `restart.log` in the support folder. Environment variables set in the original shell are not recorded.

## Limits

- LocoHost sees only processes owned by your user. A port held by root or another user shows as taken in `locohost who` and is never listed.
- Docker containers show as Docker's own process, which is protected. LocoHost does not stop containers.
- Activity is new connections and CPU, not bytes. A server that answers one long-running request with no new connection looks quiet. The review sees the open connection and the client.
- The app is not notarised. Building locally avoids Gatekeeper.
