#import "Review.h"
#import "Intel.h"

static const NSTimeInterval kTimeout = 240;

NSArray<NSArray<NSString *> *> *LHModels(void) {
    return @[@[@"auto", @"Haiku or Luna"], @[@"haiku", @"Haiku"], @[@"sonnet", @"Sonnet"], @[@"opus", @"Opus"], @[@"luna", @"Luna"]];
}

NSString *LHModelLabel(NSString *alias) {
    for (NSArray *m in LHModels()) if ([m[0] isEqualToString:alias]) return m[1];
    if ([alias hasPrefix:@"gpt-"])   // gpt-6-luna reads GPT-6-Luna, as Codex names it
        return [@"GPT" stringByAppendingString:[alias substringFromIndex:3].capitalizedString];
    return alias;
}

static BOOL IsCodexModel(NSString *m) { return [m isEqualToString:@"luna"] || [m hasPrefix:@"gpt-"]; }

@implementation LHVerdict @end

@implementation LHReview

static NSString *ReviewPath(void) { return [LHSupportDir() stringByAppendingPathComponent:@"review.json"]; }

+ (instancetype)load {
    NSData *d = [NSData dataWithContentsOfFile:ReviewPath()];
    NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![j isKindOfClass:NSDictionary.class]) return nil;
    LHReview *r = [LHReview new];
    r.at = [NSDate dateWithTimeIntervalSince1970:[j[@"at"] doubleValue]];
    r.model = j[@"model"]; r.error = [j[@"error"] isKindOfClass:NSString.class] ? j[@"error"] : nil;
    r.note = [j[@"note"] isKindOfClass:NSString.class] ? j[@"note"] : nil;
    r.tokens = [j[@"tokens"] integerValue]; r.hostCount = [j[@"hostCount"] integerValue];
    r.seconds = [j[@"seconds"] doubleValue]; r.costUSD = [j[@"costUSD"] doubleValue];
    NSMutableDictionary *v = [NSMutableDictionary new];
    NSDictionary *hosts = [j[@"hosts"] isKindOfClass:NSDictionary.class] ? j[@"hosts"] : @{};
    for (NSString *k in hosts) {
        LHVerdict *x = [LHVerdict new];
        x.verdict = hosts[k][@"verdict"]; x.about = hosts[k][@"about"]; x.reason = hosts[k][@"reason"];
        x.what = hosts[k][@"what"]; x.how = hosts[k][@"how"]; x.why = hosts[k][@"why"]; x.waste = hosts[k][@"waste"]; x.recommendation = hosts[k][@"recommendation"];
        x.confidence = [hosts[k][@"confidence"] doubleValue];
        v[k] = x;
    }
    r.verdicts = v;
    return r;
}

- (void)save {
    NSMutableDictionary *hosts = [NSMutableDictionary new];
    for (NSString *k in self.verdicts) {
        LHVerdict *x = self.verdicts[k];
        hosts[k] = @{@"verdict": x.verdict ?: @"unsure", @"about": x.about ?: @"", @"reason": x.reason ?: @"", @"confidence": @(x.confidence),
                     @"what": x.what ?: @"", @"how": x.how ?: @"", @"why": x.why ?: @"", @"waste": x.waste ?: @"", @"recommendation": x.recommendation ?: @""};
    }
    NSDictionary *j = @{@"at": @(self.at.timeIntervalSince1970), @"model": self.model ?: @"", @"error": self.error ?: NSNull.null, @"note": self.note ?: NSNull.null,
                        @"tokens": @(self.tokens), @"hostCount": @(self.hostCount), @"seconds": @(self.seconds),
                        @"costUSD": @(self.costUSD), @"hosts": hosts};
    [NSFileManager.defaultManager createDirectoryAtPath:LHSupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSJSONSerialization dataWithJSONObject:j options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil]
        writeToFile:ReviewPath() atomically:YES];
}

@end

/// Removes values that look like secrets: key=value pairs with a secret-sounding key, the value after
/// a --token style flag, passwords in URLs, and long opaque strings.
NSString *LHRedact(NSString *s) {
    static NSArray<NSArray *> *rules; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *word = @"(?:token|secret|password|passwd|pwd|api[_-]?key|apikey|auth|credential|private[_-]?key|session|cookie|bearer)";
        rules = @[
            @[[NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"(?i)(\\b[\\w.-]*%@[\\w.-]*\\s*[=:]\\s*)[^\\s'\"]+", word] options:0 error:nil], @"$1<redacted>"],
            @[[NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"(?i)(--?[\\w-]*%@[\\w-]*\\s+)[^\\s-][^\\s]*", word] options:0 error:nil], @"$1<redacted>"],
            @[[NSRegularExpression regularExpressionWithPattern:@"(://)[^/\\s:@]+:[^/\\s@]+@" options:0 error:nil], @"$1<redacted>@"],
            @[[NSRegularExpression regularExpressionWithPattern:@"[A-Za-z0-9+_\\-]{40,}" options:0 error:nil], @"<redacted>"]];
    });
    NSMutableString *m = [s mutableCopy];
    for (NSArray *r in rules) [r[0] replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:r[1]];
    return m;
}

/// The command line as the model sees it. BEAM's long runtime flags are dropped; what follows -extra is what was run.
static NSString *CommandFor(LHHost *h) {
    NSArray *a = h.args;
    NSUInteger extra = [a indexOfObject:@"-extra"];
    if ([h.name isEqualToString:@"beam.smp"] && extra != NSNotFound)
        a = [@[@"beam.smp", @"…"] arrayByAddingObjectsFromArray:[a subarrayWithRange:NSMakeRange(extra + 1, a.count - extra - 1)]];
    NSString *cmd = LHRedact([a componentsJoinedByString:@" "]);
    if (h.wrapperArgs.count) cmd = [NSString stringWithFormat:@"%@   (started by: %@)", cmd, LHRedact([h.wrapperArgs componentsJoinedByString:@" "])];
    cmd = [cmd stringByReplacingOccurrencesOfString:NSHomeDirectory() withString:@"~"];
    return cmd.length > 400 ? [[cmd substringToIndex:400] stringByAppendingString:@"…"] : cmd;
}

static id Minutes(NSDate *d) { return d ? @((long)round(-d.timeIntervalSinceNow / 60)) : NSNull.null; }

NSDictionary *LHWasteFacts(LHHost *h) {
    return @{@"since": h.lastActive ? @"last activity" : @"LocoHost first saw it", @"since_minutes": Minutes(h.lastActive ?: h.firstSeen),
             @"cpu_minutes_since": @(round(h.idleCPUSeconds / 6) / 10),
             @"energy_wh_since": h.energyJoules > 0 ? @(round(h.idleJoules / 3.6) / 1000) : NSNull.null,
             @"energy_wh_total": h.energyJoules > 0 ? @(round(h.energyJoules / 3.6) / 1000) : NSNull.null,
             @"memory_mb_held": @(h.memory >> 20)};
}

static NSString *const kSystem =
    @"You review the local servers running on a developer's Mac and decide which ones the developer still uses. "
    @"The developer runs many coding agents and git worktrees at once, so servers are often left behind when an agent or terminal finishes.\n\n"
    @"For every host return: id (copied exactly), verdict (in_use, idle or unsure), confidence from 0 to 1, "
    @"about (at most 12 words saying what the server is, for example \"Vite dev server for barkpark studio, worktree page-builder\"), "
    @"and reason (one sentence naming the facts that decided it).\n\n"
    @"Evidence, strongest first:\n"
    @"- minutes_since_activity counts from the last new connection or real CPU work. Below quiet_after_minutes: in_use.\n"
    @"- new_connections_now above 0 or cpu_busy_now true: in_use.\n"
    @"- connections_now and clients_now are connections held open, often a browser tab with a live-reload socket. "
    @"Open connections with no activity for hours usually mean a forgotten tab: that alone does not make it in_use.\n"
    @"- a live agent started it (agent is set and parent_exited is false) and the repo was touched in the last hour: in_use or unsure, never idle.\n"
    @"- parent_exited true, no activity while watched, and the repo untouched for hours: idle.\n"
    @"- two hosts for the same project and branch: the one without activity is likely idle.\n"
    @"- kind service (databases and shared infrastructure): in_use unless nothing has connected for a long time; prefer unsure.\n"
    @"- watched_minutes small means LocoHost has not watched long enough; prefer unsure unless parent_exited is true and uptime is days.\n\n"
    @"Say idle only when you would bet the developer will not miss it. Closing a server the developer needs costs more than leaving an idle one running. "
    @"Return exactly one entry for every host id.\n\n"
    @"LocoHost also investigated each dev server. project holds the package.json name, description and the script it runs, "
    @"the README's first heading and paragraph, and the names of framework config files. git holds the last commit, uncommitted files, "
    @"the upstream (\"gone\" means the remote branch was deleted, usually after a merge) and commits_not_in_default "
    @"(0 means everything on this checkout is already in the default branch). agent_session is the coding agent session that was open "
    @"when the server started, with its title or first prompt; null means no session was found, and you must not invent one. "
    @"waste is what the server burned since it was last used: CPU minutes, energy in Wh where the Mac measures it, and the memory it holds. "
    @"duplicates lists other dev servers on the same folder and branch.\n"
    @"More evidence: upstream gone with commits_not_in_default 0 means the work was merged and the server is likely left over. "
    @"An agent session last active hours ago, with parent_exited true, means the task that needed the server is over. "
    @"Of duplicates, the one without activity is likely idle.\n\n"
    @"Also return, each as one plain sentence of at most 25 words built only from the facts: "
    @"what (what the project and server are), how (how it runs: command, script, framework, what started it), "
    @"why (why it is running: the agent session's task, or the branch and last commit; say no agent session was found when it is null), "
    @"waste (what it costs while unused, with the numbers), and recommendation (keep, stop or check, and the deciding fact). "
    @"For services and other listeners keep why, waste and recommendation short.";

static NSString *Schema(void) {
    NSDictionary *s = @{@"type": @"object", @"additionalProperties": @NO, @"required": @[@"hosts"], @"properties": @{@"hosts": @{@"type": @"array", @"items": @{
        @"type": @"object", @"additionalProperties": @NO,
        @"required": @[@"id", @"verdict", @"confidence", @"about", @"reason", @"what", @"how", @"why", @"waste", @"recommendation"],
        @"properties": @{@"id": @{@"type": @"string"}, @"verdict": @{@"type": @"string", @"enum": @[@"in_use", @"idle", @"unsure"]},
                         @"confidence": @{@"type": @"number"}, @"about": @{@"type": @"string"}, @"reason": @{@"type": @"string"},
                         @"what": @{@"type": @"string"}, @"how": @{@"type": @"string"}, @"why": @{@"type": @"string"},
                         @"waste": @{@"type": @"string"}, @"recommendation": @{@"type": @"string"}}}}}};
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:s options:0 error:nil] encoding:NSUTF8StringEncoding];
}

/// A CLI by name: the test variable, the setting, the usual install paths, then a login shell's PATH.
static NSString *FindTool(NSString *name, NSString *envKey, NSString *prefKey, NSArray<NSString *> *paths) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *env = NSProcessInfo.processInfo.environment[envKey];
    if (env.length) return env;
    id pref = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)prefKey, CFSTR("no.guerrilla.locohost")));
    if ([pref isKindOfClass:NSString.class] && [fm isExecutableFileAtPath:pref]) return pref;
    for (NSString *p in paths)
        if ([fm isExecutableFileAtPath:p.stringByExpandingTildeInPath]) return p.stringByExpandingTildeInPath;
    // Last resort: ask a login shell, which knows the user's PATH. whence -p skips aliases.
    NSTask *t = [NSTask new]; NSPipe *out = [NSPipe pipe];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/zsh"]; t.arguments = @[@"-lc", [@"whence -p " stringByAppendingString:name]];
    t.standardOutput = out; t.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![t launchAndReturnError:nil]) return nil;
    [t waitUntilExit];
    NSString *p = [[[NSString alloc] initWithData:[out.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding]
                   stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [fm isExecutableFileAtPath:p] ? p : nil;
}

/// Runs a CLI with the prompt on stdin, in the support folder, with the given variables removed.
/// Returns NO with *error set when it could not start or did not finish in time.
static BOOL Run(NSString *path, NSArray *args, NSData *input, BOOL (^drop)(NSString *key), NSData **outData, NSData **errData, int *status, NSString **error) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:path];
    t.arguments = args;
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    for (NSString *k in env.allKeys) if (drop(k)) [env removeObjectForKey:k];
    env[@"PATH"] = [NSString stringWithFormat:@"%@:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", [@"~/.local/bin" stringByExpandingTildeInPath]];
    t.environment = env;
    [NSFileManager.defaultManager createDirectoryAtPath:LHSupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
    t.currentDirectoryURL = [NSURL fileURLWithPath:LHSupportDir()];   // no project CLAUDE.md or AGENTS.md is picked up
    NSPipe *in = [NSPipe pipe], *out = [NSPipe pipe], *err = [NSPipe pipe];
    t.standardInput = in; t.standardOutput = out; t.standardError = err;
    NSError *e = nil;
    if (![t launchAndReturnError:&e]) { *error = [NSString stringWithFormat:@"could not start %@: %@", path.lastPathComponent, e.localizedDescription]; return NO; }
    [in.fileHandleForWriting writeData:input];
    [in.fileHandleForWriting closeFile];

    __block NSData *o = nil, *x = nil;
    dispatch_group_t g = dispatch_group_create();
    dispatch_group_async(g, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ o = [out.fileHandleForReading readDataToEndOfFile]; });
    dispatch_group_async(g, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ x = [err.fileHandleForReading readDataToEndOfFile]; });
    if (dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTimeout * NSEC_PER_SEC))) != 0) {
        [t terminate];
        *error = [NSString stringWithFormat:@"%@ did not answer within %.0f seconds", path.lastPathComponent, kTimeout];
        return NO;
    }
    [t waitUntilExit];
    *outData = o; *errData = x; *status = t.terminationStatus;
    return YES;
}

static NSString *Trimmed(NSData *d, NSUInteger max) {
    NSString *s = [[[NSString alloc] initWithData:d ?: NSData.data encoding:NSUTF8StringEncoding] ?: @""
                   stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return s.length > max ? [s substringToIndex:max] : s;
}

/// Claude through `claude -p`. Returns the structured answer, or nil with r.error set.
static NSDictionary *AskClaude(LHReview *r, NSString *claude, NSString *model, NSData *prompt) {
    NSArray *args = @[@"-p", @"--model", model, @"--output-format", @"json", @"--json-schema", Schema(), @"--tools", @"",
                      @"--no-session-persistence", @"--strict-mcp-config", @"--setting-sources", @"", @"--system-prompt", kSystem];
    // The user's own Claude login, never an API key from the environment, and not a nested session of the agent that launched us.
    NSArray *dropped = @[@"ANTHROPIC_API_KEY", @"ANTHROPIC_AUTH_TOKEN", @"CLAUDECODE", @"CLAUDE_CODE_ENTRYPOINT", @"CLAUDE_CODE_SSE_PORT"];
    NSData *out, *err; int status; NSString *e = nil;
    r.model = model;
    if (!Run(claude, args, prompt, ^BOOL(NSString *k) { return [dropped containsObject:k]; }, &out, &err, &status, &e)) { r.error = e; return nil; }

    NSDictionary *j = out.length ? [NSJSONSerialization JSONObjectWithData:out options:0 error:nil] : nil;
    if (![j isKindOfClass:NSDictionary.class]) {
        NSString *msg = Trimmed(err.length ? err : out, 300);
        r.error = msg.length ? msg : [NSString stringWithFormat:@"claude exited with status %d", status];
        return nil;
    }
    NSDictionary *u = j[@"usage"];
    r.tokens = [u[@"input_tokens"] integerValue] + [u[@"output_tokens"] integerValue] +
               [u[@"cache_creation_input_tokens"] integerValue] + [u[@"cache_read_input_tokens"] integerValue];
    r.costUSD = [j[@"total_cost_usd"] doubleValue];
    if ([j[@"is_error"] boolValue]) { r.error = [j[@"result"] description] ?: @"claude reported an error"; return nil; }
    id so = j[@"structured_output"];
    if (![so isKindOfClass:NSDictionary.class]) {
        NSData *d = [[j[@"result"] description] dataUsingEncoding:NSUTF8StringEncoding];
        so = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    }
    if (![so isKindOfClass:NSDictionary.class]) { r.error = @"the answer did not match the schema"; return nil; }
    return so;
}

/// The Luna models Codex offers this account, newest first as Codex lists them, then the known names.
static NSArray<NSString *> *LunaModels(void) {
    NSString *home = NSProcessInfo.processInfo.environment[@"CODEX_HOME"] ?: [@"~/.codex" stringByExpandingTildeInPath];
    NSData *d = [NSData dataWithContentsOfFile:[home stringByAppendingPathComponent:@"models_cache.json"]];
    NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    NSMutableArray *l = [NSMutableArray new];
    if ([j isKindOfClass:NSDictionary.class] && [j[@"models"] isKindOfClass:NSArray.class])
        for (NSDictionary *m in j[@"models"])
            if ([m isKindOfClass:NSDictionary.class] && [m[@"slug"] isKindOfClass:NSString.class] && [m[@"slug"] containsString:@"luna"]) [l addObject:m[@"slug"]];
    for (NSString *m in @[@"gpt-6-luna", @"gpt-5.6-luna"]) if (![l containsObject:m]) [l addObject:m];
    return l;
}

/// A TOML basic string, for codex -c key=value.
static NSString *TOMLString(NSString *s) {
    s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    s = [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    return [NSString stringWithFormat:@"\"%@\"", s];
}

/// The message inside a codex error, which is often an API error body as JSON.
static NSString *CodexMessage(NSString *m) {
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[m dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data options:0 error:nil];
    if ([j isKindOfClass:NSDictionary.class] && [j[@"error"] isKindOfClass:NSDictionary.class] && [j[@"error"][@"message"] isKindOfClass:NSString.class])
        return j[@"error"][@"message"];
    return m;
}

/// OpenAI through `codex exec`. Every tool is turned off and the sandbox is read-only, so the model only answers.
static NSDictionary *AskCodexModel(LHReview *r, NSString *codex, NSString *model, NSData *prompt) {
    NSString *dir = LHSupportDir();
    NSString *schema = [dir stringByAppendingPathComponent:@"review-schema.json"], *answer = [dir stringByAppendingPathComponent:@"review-answer.json"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [Schema() writeToFile:schema atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [NSFileManager.defaultManager removeItemAtPath:answer error:nil];
    NSMutableArray *args = [@[@"exec", @"--model", model, @"--json", @"--output-schema", schema, @"--output-last-message", answer,
                              @"--sandbox", @"read-only", @"--skip-git-repo-check", @"--ephemeral", @"--ignore-user-config", @"--ignore-rules",
                              @"-c", @"model_reasoning_effort=\"low\"", @"-c", @"web_search=\"disabled\"", @"-c", @"approval_policy=\"never\"",
                              @"-c", @"include_apply_patch_tool=false", @"-c", @"features.multi_agent=false",
                              @"-c", [@"developer_instructions=" stringByAppendingString:TOMLString(kSystem)]] mutableCopy];
    for (NSString *f in @[@"shell_tool", @"unified_exec", @"apps", @"plugins", @"browser_use", @"computer_use", @"image_generation",
                          @"multi_agent", @"hooks", @"view_image", @"skill_search", @"tool_suggest", @"goals", @"sleep_tool"])
        [args addObjectsFromArray:@[@"--disable", f]];
    [args addObject:@"-"];
    // The user's ChatGPT login from ~/.codex, never an API key from the environment, and not a nested session of a running Codex.
    NSData *out, *err; int status; NSString *e = nil;
    r.model = model;
    BOOL ran = Run(codex, args, prompt, ^BOOL(NSString *k) {
        return [@[@"OPENAI_API_KEY", @"OPENAI_BASE_URL"] containsObject:k] || ([k hasPrefix:@"CODEX_"] && ![k isEqualToString:@"CODEX_HOME"]);
    }, &out, &err, &status, &e);
    if (!ran) { r.error = e; return nil; }

    NSString *failure = nil;
    for (NSString *line in [[[NSString alloc] initWithData:out ?: NSData.data encoding:NSUTF8StringEncoding] componentsSeparatedByString:@"\n"]) {
        NSDictionary *ev = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data options:0 error:nil];
        if (![ev isKindOfClass:NSDictionary.class]) continue;
        if ([ev[@"type"] isEqual:@"turn.completed"]) {
            NSDictionary *u = ev[@"usage"];
            r.tokens += [u[@"input_tokens"] integerValue] + [u[@"output_tokens"] integerValue];
        } else if ([ev[@"type"] isEqual:@"turn.failed"] && [ev[@"error"][@"message"] isKindOfClass:NSString.class]) {
            failure = CodexMessage(ev[@"error"][@"message"]);
        } else if ([ev[@"type"] isEqual:@"error"] && [ev[@"message"] isKindOfClass:NSString.class]) {
            failure = failure ?: CodexMessage(ev[@"message"]);
        }
    }
    NSData *d = [NSData dataWithContentsOfFile:answer];
    id so = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if ([so isKindOfClass:NSDictionary.class]) return so;
    NSString *msg = failure ?: Trimmed(err, 300);
    r.error = msg.length ? [msg substringToIndex:MIN(300, msg.length)] : [NSString stringWithFormat:@"codex exited with status %d", status];
    return nil;
}

/// "luna" tries each Luna model this account offers, moving on only when the account cannot use that model.
static NSDictionary *AskCodex(LHReview *r, NSString *codex, NSString *model, NSData *prompt) {
    NSArray *models = [model isEqualToString:@"luna"] ? LunaModels() : @[model];
    for (NSString *m in models) {
        r.error = nil;
        NSDictionary *so = AskCodexModel(r, codex, m, prompt);
        if (so) return so;
        if (!([r.error containsString:@"not supported"] || [r.error containsString:@"model_not_found"] || [r.error containsString:@"does not exist"])) return nil;
    }
    return nil;
}

@implementation LHReviewer

+ (NSString *)claudePath {
    return FindTool(@"claude", @"LOCOHOST_CLAUDE", @"locohost.claudePath",
                    @[@"~/.local/bin/claude", @"~/.claude/local/claude", @"/opt/homebrew/bin/claude", @"/usr/local/bin/claude", @"~/.npm-global/bin/claude", @"~/.bun/bin/claude"]);
}

+ (NSString *)codexPath {
    return FindTool(@"codex", @"LOCOHOST_CODEX", @"locohost.codexPath",
                    @[@"~/.local/bin/codex", @"/opt/homebrew/bin/codex", @"/usr/local/bin/codex", @"~/.npm-global/bin/codex", @"~/.bun/bin/codex"]);
}

+ (NSArray<NSDictionary *> *)factsFor:(NSArray<LHHost *> *)hosts scanner:(LHScanner *)scanner {
    NSMutableArray *facts = [NSMutableArray new];
    for (LHHost *h in hosts) {
        NSMutableDictionary *f = [@{@"id": h.key, @"ports": h.ports, @"bind": h.bind ?: @"", @"kind": h.kind, @"framework": h.framework,
                           @"command": CommandFor(h), @"project": h.project, @"branch": h.branch ?: NSNull.null,
                           @"worktree": h.worktree ?: NSNull.null, @"launcher": h.launcher ?: @"", @"agent": h.agent ?: NSNull.null,
                           @"parent_exited": @(h.orphaned), @"uptime_minutes": Minutes(h.started),
                           @"cpu_percent_now": @(round(h.cpuPercent * 10) / 10), @"cpu_minutes_total": @(round(h.cpuSeconds / 6) / 10),
                           @"memory_mb": @(h.memory >> 20), @"processes": @(h.processCount),
                           @"connections_now": @(h.connections), @"new_connections_now": @(h.newConnections),
                           @"clients_now": h.clients ?: @[], @"cpu_busy_now": @(h.busy),
                           @"minutes_since_activity": Minutes(h.lastActive), @"watched_minutes": Minutes(h.firstSeen),
                           @"repo_touched_minutes_ago": Minutes(h.repoTouched), @"page_title": h.title ?: NSNull.null,
                           @"http_status": @(h.httpStatus), @"protected": @(h.isProtected)} mutableCopy];
        f[@"waste"] = LHWasteFacts(h);
        f[@"duplicates"] = h.duplicates ?: @[];
        if ([h.kind isEqualToString:@"dev"]) {
            NSDictionary *intel = LHIntel(h, YES);
            NSMutableDictionary *session = [intel[@"session"] mutableCopy];
            [session removeObjectForKey:@"file"];   // a local path, not evidence
            f[@"project"] = intel[@"project"] ?: NSNull.null;
            f[@"git"] = intel[@"git"] ?: NSNull.null;
            f[@"agent_session"] = session ?: NSNull.null;
        }
        [facts addObject:f];
    }
    return facts;
}

+ (LHReview *)review:(NSArray<LHHost *> *)hosts scanner:(LHScanner *)scanner model:(NSString *)model {
    LHReview *r = [LHReview new];
    r.at = NSDate.date; r.model = model; r.hostCount = hosts.count; r.verdicts = @{};
    if (!hosts.count) return r;

    NSDictionary *input = @{@"now": [NSISO8601DateFormatter stringFromDate:NSDate.date timeZone:NSTimeZone.localTimeZone formatOptions:NSISO8601DateFormatWithInternetDateTime],
                            @"quiet_after_minutes": @((long)(scanner.idleSeconds / 60)),
                            @"locohost_watching_minutes": Minutes(scanner.watchingSince),
                            @"hosts": [self factsFor:hosts scanner:scanner]};
    NSData *prompt = [NSJSONSerialization dataWithJSONObject:input options:NSJSONWritingPrettyPrinted error:nil];

    NSDictionary *so = nil;
    if ([model isEqualToString:@"auto"]) {
        // Haiku first. Luna when claude is missing, signed out, out of usage or fails in any other way.
        NSString *claude = [self claudePath], *codex = nil;
        if (claude) so = AskClaude(r, claude, @"haiku", prompt);
        if (!so) {
            NSString *why = claude ? r.error : @"claude CLI not found";
            r.note = [NSString stringWithFormat:@"Haiku: %@", why];
            r.error = nil; r.tokens = 0; r.costUSD = 0;
            if ((codex = [self codexPath])) so = AskCodex(r, codex, @"luna", prompt);
            else r.error = @"codex CLI not found";
            if (!so) r.error = [NSString stringWithFormat:@"%@. Luna: %@", r.note, r.error];
        }
    } else if (IsCodexModel(model)) {
        NSString *codex = [self codexPath];
        if (codex) so = AskCodex(r, codex, model, prompt);
        else r.error = @"codex CLI not found. Install Codex and sign in, or set locohost.codexPath.";
    } else {
        NSString *claude = [self claudePath];
        if (claude) so = AskClaude(r, claude, model, prompt);
        else r.error = @"claude CLI not found. Install Claude Code and sign in, or set locohost.claudePath.";
    }
    r.seconds = -r.at.timeIntervalSinceNow;
    if (!so) return r;

    NSArray *list = so[@"hosts"];
    if (![list isKindOfClass:NSArray.class]) { r.error = @"the answer did not match the schema"; return r; }
    NSSet *keys = [NSSet setWithArray:[hosts valueForKey:@"key"]];
    NSMutableDictionary *v = [NSMutableDictionary new];
    for (NSDictionary *x in list) {
        if (![x isKindOfClass:NSDictionary.class] || ![keys containsObject:x[@"id"]]) continue;
        LHVerdict *vv = [LHVerdict new];
        vv.verdict = [@[@"in_use", @"idle", @"unsure"] containsObject:x[@"verdict"]] ? x[@"verdict"] : @"unsure";
        vv.confidence = MAX(0, MIN(1, [x[@"confidence"] doubleValue]));
        vv.about = [x[@"about"] description]; vv.reason = [x[@"reason"] description];
        vv.what = [x[@"what"] description]; vv.how = [x[@"how"] description]; vv.why = [x[@"why"] description];
        vv.waste = [x[@"waste"] description]; vv.recommendation = [x[@"recommendation"] description];
        v[x[@"id"]] = vv;
    }
    r.verdicts = v;
    return r;
}

@end
