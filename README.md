<p align="center"><img src="docs/app-icon.png" width="128" alt="LocoHost icon: a server rack with a crescent moon."></p>

# LocoHost

**Every localhost on your Mac, and whether you still use it.**

LocoHost is a free menu bar app for Macs that run many coding agents and git worktrees at once. Each agent starts a dev server, the agent finishes, and the server keeps running for days. LocoHost lists every one of them and finds out what each one is, why it is there, and what it burns while nobody uses it. Haiku or Luna, on your own subscription, checks the list every hour. **Close Idle** stops the servers nobody uses, in one click.

Free and MIT licensed · macOS 13 or newer · [Install](#install) · [How it works](docs/HOW-IT-WORKS.md) · [The review](docs/REVIEW.md)

## What it looks like

![A drawing of the LocoHost menu. The top line counts 11 localhosts, 4 in use, 3 quiet, 21% CPU and 9.0 GB. Close Idle offers to stop 3 servers holding 1.5 GB. Below are the servers in use, such as Vite on port 3317 open in headless Chrome, the quiet ones, such as two Phoenix servers up for 12 and 7 days that nobody has used for 3 hours, and Postgres under Services.](docs/images/menu.svg)

Each row opens a submenu with the page title, folder, branch and worktree, the full command, and what started it. It also shows who is connected now and the review's verdict with its reason. From there you can Open, Copy URL, Reveal Folder, Copy Restart Command, Protect, Stop or Force Stop.

## What LocoHost finds out

LocoHost investigates every dev server before it asks the model. [What it reads](docs/HOW-IT-WORKS.md#investigation)

- **What it is.** The name, description and script from `package.json`, the first lines of the README, the app in `mix.exs` or `pyproject.toml`, and the names of its config files. It never opens `.env` files.
- **Why it is there.** The Claude Code, Codex or pi session that started it, with its title and when it was last active. When no session matches, LocoHost says "no agent session found" instead of guessing.
- **Where the work stands.** The last commit, uncommitted files, whether the remote branch still exists, and how many commits are not in the default branch yet.
- **What it wastes.** CPU time, energy in Wh and memory held since anyone last used it, from the kernel's own counters for the whole process tree. Two servers on the same folder and branch are flagged as duplicates.

The model turns this into five short sentences per server: what, how, why, waste and a recommendation. `locohost explain 3317` prints them with the evidence:

```
What      Vite dev server for barkpark-studio-app on the fix/page-builder-array branch, port 3317.
How       Started by npm exec vite dev --port 3317 --strictPort; its parent exited, and no client is connected now.
Why       No agent session was found; the branch has 2 commits not in origin/main and is 9 ahead of its upstream.
Waste     Holds 741 MB; 0 CPU minutes and 0.002 Wh since last activity, 2 minutes ago.
Advice    Keep: it was active 2 minutes ago and has local commits ahead of its upstream; recheck after 30 quiet minutes.
```

## How LocoHost decides

Closing a server you need costs more than leaving an idle one running. [Step by step](docs/HOW-IT-WORKS.md) · [Rules file](docs/RULES.md)

- **Watches what happens, not what is open.** Activity is a new connection or real CPU work. A forgotten tab with a live-reload socket is not use, and neither is a spinning BEAM scheduler.
- **Knows who started it.** `pnpm dev` under Claude Code in cmux, a `mix phx.server` whose terminal is gone, or a Playwright browser still connected. A server whose parent exited is the most common leftover.
- **Asks a model, then checks again.** The review alone never closes anything. Two checks have to agree, and anything that happens after the review cancels it.
- **Leaves the rest alone.** Postgres, Redis, epmd, Docker and Ollama are never closed, and neither are ports you protect. Spotify, AirPlay and other macOS and app listeners are only listed.

![Two checks have to agree. One: LocoHost saw no new connection and no real CPU work for 30 minutes. Two: the latest review by Haiku or Luna called the server idle with at least 60 percent confidence, and nothing happened after it. Then Close Idle stops it, dev servers only, with SIGTERM, six seconds, then your setting.](docs/images/close-idle.svg)

![The review. LocoHost writes down the facts about each server with secrets redacted, asks Haiku through the claude CLI, and asks Luna through the codex CLI when Haiku can't answer. Neither has tools. The answer is one verdict per server: in use, idle or unsure, with a confidence and a reason.](docs/images/review.svg)

## Your subscription, no tools

The review runs on the login your `claude` or `codex` CLI already has, the same way T3 Code and Barkdown use it. API keys in the environment are removed, so nothing is billed per call. The model gets the facts LocoHost gathered and answers in a fixed schema. It cannot run a command or read a file. Everything sent is redacted first. [What is sent](docs/REVIEW.md#what-is-sent)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/FRIKKern/locohost/main/install.sh | sh
```

It builds from source in a few seconds with Apple's Command Line Tools, so there is no Gatekeeper prompt. You get `~/Applications/LocoHost.app` and a `locohost` command in `~/.local/bin`. Add `LOCOHOST_LOGIN=1` to start it at login.

On first launch macOS asks whether LocoHost may read your Documents folder. LocoHost needs that to read each project's `.git` for the branch and worktree. The review needs [Claude Code](https://claude.com/claude-code) or [Codex](https://github.com/openai/codex), signed in. Everything else works without them.

## For agents

The `locohost` command answers what an agent asks before it starts a server.

```sh
PORT=$(locohost free 3000)                     # the first free port at or above 3000
pnpm dev --port "$PORT" &
locohost ready "$PORT" --http --timeout 90     # exit 0 once it answers HTTP
locohost who 3000                              # who holds :3000, from which folder and branch
locohost explain 3000                          # what it is, why it is there, what it wastes
locohost waste                                 # every server ranked by what it burns unused
```

[Every command](docs/CLI.md)

## For developers

```sh
git clone https://github.com/FRIKKern/locohost.git && cd locohost
./build.sh && ./test.sh
```

Objective-C built with clang alone. No Xcode project, no Swift, no packages. `test.sh` runs 35 checks against its own Python servers and fake `claude` and `codex` CLIs, and never touches another server.

| I want to … | Read this |
|---|---|
| understand what LocoHost reads and when it stops a server | [How it works](docs/HOW-IT-WORKS.md) |
| see exactly what the model gets and how Luna takes over | [The review](docs/REVIEW.md) |
| protect a server or hide a listener | [Rules file](docs/RULES.md) |
| script it or use it from an agent | [CLI](docs/CLI.md) |
| change the code | [AGENTS.md](AGENTS.md), [CHANGELOG](CHANGELOG.md) |

Part of a family. [Insomnia](https://github.com/FRIKKern/insomnia) keeps the Mac awake, [MinMacs](https://github.com/FRIKKern/minmacs) keeps the CPU and RAM for what matters, and LocoHost keeps the ports for what you use. MIT. Made by [Frikk Jarl](https://github.com/FRIKKern).
