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

## Close Idle

A server is stopped by Close Idle only when all of these hold:

1. It is a dev server, not a service such as Postgres, Redis or epmd.
2. It is not protected by name, port or folder in `rules.json`.
3. LocoHost saw no new connection and no real CPU work for the quiet threshold.
4. The latest review that did not fail called it idle with at least 60% confidence.
5. Nothing happened after that review.

Close Idle samples again right before it stops anything. What it stops is what the confirmation listed.

## Stopping

Every server gets SIGTERM and six seconds to stop. The package manager wrapper above it gets the signal too, when the server is its only child. Shells and agents above it are never signalled.

What happens to a server that refuses is your setting under *When a Server Won't Stop*: ask me, force stop it, or leave it running. Before every signal, LocoHost checks the process start time, so a reused pid is never signalled.

*Recently Stopped* keeps the command that starts each server again. Environment variables set in the original shell are not recorded.

## Limits

- LocoHost sees only processes owned by your user. A port held by root or another user shows as taken in `locohost who` and is never listed.
- Docker containers show as Docker's own process, which is protected. LocoHost does not stop containers.
- Activity is new connections and CPU, not bytes. A server that answers one long-running request with no new connection looks quiet. The review sees the open connection and the client.
- The app is not notarised. Building locally avoids Gatekeeper.
