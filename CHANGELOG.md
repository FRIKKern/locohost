# Changelog

All notable changes to LocoHost. Format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- Luna through the codex CLI on the user's ChatGPT login, with every tool off and a read-only sandbox. The Luna models come from Codex's own model list, and one the account cannot use is skipped.
- The model "Haiku or Luna" is the new default. It asks Haiku first and asks Luna when claude is missing, signed out, out of usage or fails. The menu and `locohost review` name the model that answered and say why Haiku was skipped.
- Investigation of every dev server: the project's package.json, README, mix.exs or pyproject.toml, git state, and the Claude Code, Codex or pi session that started it. `.env` files are never opened.
- Waste per server: CPU time, energy in Wh and memory held since it was last used, from the kernel's counters for the whole process tree. Duplicates on the same folder and branch are flagged.
- The review returns what, how, why, waste and a recommendation for each server. They show in each row's submenu, in `locohost explain <port>` and in `locohost who`. `locohost waste` ranks servers by what they burn unused.

- Three modes. Idle reviews and reports. Proactive stops servers quiet for six hours with no agent above them that the review is sure about. Eager, the default, stops every quiet server that can't show evidence that someone needs it, after a second model pass, the judge. No mode stops a server used in the quiet window, younger than 30 minutes, protected, or with an agent session active in the last hour.
- Reviews wake on events as well as the schedule: a new dev server, uptime passing a day, three days or a week, memory pressure, and sustained load. Event reviews are at least ten minutes apart.
- Each review writes a summary of the whole Mac, shown at the top of the menu and by `locohost summary`.
- `locohost mode`, `locohost summary` and `locohost auto` with `--dry-run`, `--mode` and `--port`. Stops by a mode are recorded with the mode and the reason, and announced in a notification.
- `test.sh` has 49 checks, including each mode, the judge, keep evidence and an active agent session.

### Fixed
- Connections from the CLI's own probe counted as visits in the menu bar app. Connections from every LocoHost process are now excluded.

## [0.1.0] - 2026-10-26

### Added
- Menu bar list of every localhost owned by your user: port, framework, project, git branch and worktree, uptime, CPU and memory over the process tree, clients connected now, page title, and what started it (package manager wrapper, agent, terminal app, or a parent that exited).
- Activity from new connections and from CPU well above the server's own average, two samples in a row. Open connections alone, such as a forgotten tab, are not activity. History in `activity.json`, shared by the app and the CLI.
- Review by a Claude model through the claude CLI on the user's own login, hourly by default: no tools, fixed JSON schema, redacted command lines. Model menu for Haiku, Sonnet and Opus, or any model name through `locohost.model`.
- Close Idle: stops dev servers that local signals and the latest review both call idle. SIGTERM, six seconds, then the user's force setting. Recently Stopped keeps restart commands.
- Protect and ignore lists in `rules.json`. Services such as Postgres, Redis, epmd, Docker and Ollama are protected by default; macOS and app listeners are ignored.
- CLI: `list`, `who`, `ready`, `free`, `review`, `idle`, `close`, `close-idle`, `stopped`, `open`, `rules`, with `--json`.
- URL scheme: `locohost://review|close-idle|login-on|login-off|quit`. Launch at Login. Universal binary. `install.sh`, `uninstall.sh`, `test.sh` with 23 checks against fixtures.
