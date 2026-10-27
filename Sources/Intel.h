#import <Foundation/Foundation.h>
#import "Ports.h"

/// What LocoHost finds out about a dev server beyond the process table. Every key is optional.
///   project  name, description, script (the package.json script it runs), readme (first heading and paragraph),
///            app (mix.exs), configs (framework config files that exist)
///   git      last_commit, last_commit_minutes_ago, last_commit_author, dirty_files, ahead, behind,
///            upstream (a name, or "gone"), default_branch, merged (HEAD is contained in the default branch)
///   session  agent, title, first_prompt, started_minutes_ago, last_active_minutes_ago, match, file
/// Only an allowlist of files is read: package.json, README, mix.exs, pyproject.toml, and the names of config files.
/// .env files are never opened. Text values are redacted and capped. Session lookups read the agents' own logs
/// under ~/.claude, ~/.codex and ~/.pi on this Mac; nothing is fetched from the network.
///
/// wait NO returns the cached answer, or nil, and reads in the background (the app). wait YES reads now (the CLI, the review).
/// Answers are cached for five minutes per host.
NSDictionary *LHIntel(LHHost *h, BOOL wait);
