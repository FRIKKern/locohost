# The review

On a schedule, hourly by default, and when you press *Review Now*, LocoHost asks a model which servers you still use. The answer is one verdict per server, `in_use`, `idle` or `unsure`, with a confidence and a one-sentence reason. It also has five short sentences: what the server is, how it runs, why it is there, what it wastes, and a recommendation.

## Haiku or Luna

The default model is *Haiku or Luna*. LocoHost asks Haiku first. It asks Luna when Haiku cannot answer. That happens when the `claude` CLI is missing, signed out or out of usage, or when its answer fails. The menu and `locohost review` say which model answered and why Haiku was skipped.

Haiku runs through the `claude` CLI headless:

```
claude -p --model haiku --output-format json --json-schema <schema> --tools "" \
       --no-session-persistence --strict-mcp-config --setting-sources "" --system-prompt <prompt>
```

Luna runs through the `codex` CLI with every tool turned off and a read-only sandbox:

```
codex exec --model gpt-6-luna --json --output-schema <schema> --output-last-message <file> \
           --sandbox read-only --ephemeral --ignore-user-config --ignore-rules \
           -c developer_instructions=<prompt> --disable shell_tool --disable unified_exec … -
```

LocoHost takes the Luna models from the list Codex keeps in `~/.codex/models_cache.json`, in Codex's order. When the account cannot use one, it tries the next. On 2026-10-27 Codex answered that `gpt-6-luna` "is not supported when using Codex with a ChatGPT account", so that account got `gpt-5.6-luna`.

## Your subscription

Both models run on the login the CLI already has, the same way T3 Code and Barkdown use it. `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and `OPENAI_API_KEY` are removed from the environment, so a key on the machine is never billed. The menu shows the token count of each review. The list price the claude CLI reports is stored, but a subscription is not billed per call.

## No tools

The model reads the facts LocoHost gathered and answers in a fixed JSON schema. It cannot run a command or read a file. LocoHost does the investigation itself, as described in [How it works](HOW-IT-WORKS.md#investigation). Both CLIs run in LocoHost's support folder, so no project `CLAUDE.md` or `AGENTS.md` is picked up.

## What is sent

For each server:

- **Process.** Ports, bind address, kind, framework, project, branch, worktree, launcher, agent, whether the parent exited, uptime, CPU and memory, and whether it is protected.
- **Command.** The command line, redacted and capped at 400 characters.
- **Use.** Connections, new connections and clients, minutes since activity, minutes watched, minutes since the repo was touched, page title and HTTP status.
- **Waste.** CPU minutes and Wh since the last activity, Wh in total, memory held, and any duplicate on the same folder and branch.

For dev servers only:

- **Project.** The `package.json` name, description and matching script, the README intro, the `mix.exs` app, the `pyproject.toml` name and description, and config file names.
- **Git.** The last commit subject, age and author, the uncommitted file count, the upstream with ahead and behind, the default branch and the commits not in it.
- **Agent session.** The agent, the session title and first prompt, when it started and was last active, how it matched, and how many other sessions matched. The path of the session log stays on your Mac.

Text is capped at 300 characters, and session text at 200. All of it is redacted first. Values after secret-looking keys and flags (`token`, `password`, `api-key`, `secret` and the like), passwords in URLs, and opaque strings of 40 or more characters become `<redacted>`. Environment variables are never read. `locohost review --json` shows the verdicts. `test.sh` checks the redaction on both the Haiku and the Luna path, checks that `.env` contents are never sent, and checks that a session prompt is redacted.

## Choosing a model

*Model* in the menu picks *Haiku or Luna*, or one of Haiku, Sonnet, Opus and Luna alone. `defaults write no.guerrilla.locohost locohost.model <name>` takes any model name. A name that starts with `gpt-` goes to codex, and any other name goes to claude. *Review Every* goes from 15 minutes to 4 hours, or Off.

## Measured

| Model | Servers | Time | Tokens |
|---|---|---|---|
| Haiku | 11 | 17 s | about 10.6k |
| Haiku | 7 | 10 s | 7.0k |
| GPT-5.6-Luna | 7 | 19 s | about 10.6k |
| Haiku, with investigation | 7 | 42 s | 17.7k |
| GPT-5.6-Luna, with investigation | 7 | 19 s | 13.6k |

These are single runs on one Mac on 2026-10-26 and 2026-10-27.
