#import "Intel.h"
#import "Review.h"

static const NSTimeInterval kIntelFresh = 300;

#pragma mark - Helpers

/// One line, redacted, at most n characters.
static NSString *Clip(NSString *s, NSUInteger n) {
    if (![s isKindOfClass:NSString.class]) return nil;
    s = [[[s componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
          filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
    s = [LHRedact(s) stringByReplacingOccurrencesOfString:NSHomeDirectory() withString:@"~"];
    if (!s.length) return nil;
    return s.length > n ? [[s substringToIndex:n - 1] stringByAppendingString:@"…"] : s;
}

static NSData *Head(NSString *path, NSUInteger max) {
    NSFileHandle *f = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *d = [f readDataUpToLength:max error:nil];
    [f closeFile];
    return d;
}

static NSString *HeadText(NSString *path, NSUInteger max) {
    NSData *d = Head(path, max);
    return d ? ([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding]) : nil;
}

static NSString *Match(NSString *s, NSString *pattern) {
    if (!s) return nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionAnchorsMatchLines error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    return m && [m rangeAtIndex:1].location != NSNotFound ? [s substringWithRange:[m rangeAtIndex:1]] : nil;
}

static NSDate *ISODate(NSString *s) {
    static NSISO8601DateFormatter *f, *g; static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [NSISO8601DateFormatter new]; f.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        g = [NSISO8601DateFormatter new];
    });
    return s ? ([f dateFromString:s] ?: [g dateFromString:s]) : nil;
}

static NSNumber *MinutesAgo(NSDate *d) { return d ? @((long)round(-d.timeIntervalSinceNow / 60)) : nil; }

static NSString *GitPath(void) {
    for (NSString *p in @[@"/Library/Developer/CommandLineTools/usr/bin/git", @"/opt/homebrew/bin/git", @"/usr/local/bin/git",
                          @"/Applications/Xcode.app/Contents/Developer/usr/bin/git"])
        if ([NSFileManager.defaultManager isExecutableFileAtPath:p]) return p;
    return nil;   // /usr/bin/git without the tools installed would ask the user to install them
}

/// git in a folder, read-only: no optional locks, no prompts, five seconds at most.
static NSString *Git(NSString *dir, NSArray *args, int *status) {
    NSString *git = GitPath();
    if (status) *status = -1;
    if (!git) return nil;
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:git];
    t.arguments = [@[@"-C", dir] arrayByAddingObjectsFromArray:args];
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"GIT_OPTIONAL_LOCKS"] = @"0"; env[@"GIT_TERMINAL_PROMPT"] = @"0";
    t.environment = env;
    NSPipe *out = [NSPipe pipe];
    t.standardOutput = out; t.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![t launchAndReturnError:nil]) return nil;
    __block NSData *d = nil;
    dispatch_group_t g = dispatch_group_create();
    dispatch_group_async(g, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ d = [out.fileHandleForReading readDataToEndOfFile]; });
    if (dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) { [t terminate]; return nil; }
    [t waitUntilExit];
    if (status) *status = t.terminationStatus;
    return [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
}

/// The folders that belong to this server: where it runs, where its package manager runs, and the repo root.
static NSArray<NSString *> *Folders(LHHost *h) {
    NSMutableOrderedSet *f = [NSMutableOrderedSet new];
    for (NSString *d in @[h.cwd ?: @"", h.wrapperCwd ?: @"", h.repoRoot ?: @""]) if (d.length > 1) [f addObject:d];
    return f.array;
}

#pragma mark - Project

static NSString *ScriptFor(LHHost *h, NSDictionary *scripts) {
    if (![scripts isKindOfClass:NSDictionary.class]) return nil;
    // `pnpm dev`, `npm run dev`, `yarn dev`: the first word after the runner that is not run or a flag.
    NSMutableArray *words = [NSMutableArray new];
    for (NSString *a in h.wrapperArgs) [words addObjectsFromArray:[a componentsSeparatedByString:@" "]];
    for (NSUInteger i = 1; i < words.count; i++) {
        NSString *w = words[i];
        if ([w hasPrefix:@"-"] || [w isEqualToString:@"run"] || [w hasSuffix:@".js"] || [w hasSuffix:@".cjs"]) continue;
        if ([scripts[w] isKindOfClass:NSString.class]) return [NSString stringWithFormat:@"%@: %@", w, scripts[w]];
        break;
    }
    NSString *cmd = [h.command stringByAppendingFormat:@" %@", [h.args componentsJoinedByString:@" "]];
    for (NSString *k in [scripts.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *v = scripts[k];
        if ([v isKindOfClass:NSString.class] && v.length > 3 && [cmd containsString:v]) return [NSString stringWithFormat:@"%@: %@", k, v];
    }
    return nil;
}

/// The first heading and the first paragraph of prose, skipping badges, images, HTML and code.
static void ReadmeIntro(NSString *text, NSString **heading, NSString **paragraph) {
    NSMutableArray *para = [NSMutableArray new];
    BOOL inCode = NO;
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *l = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([l hasPrefix:@"```"]) { inCode = !inCode; if (para.count) break; continue; }
        if (inCode) continue;
        if ([l hasPrefix:@"#"]) {
            if (!*heading) *heading = [l stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"# "]];
            if (para.count) break;
            continue;
        }
        if (!l.length) { if (para.count) break; continue; }
        if ([l hasPrefix:@"!["] || [l hasPrefix:@"[!["] || [l hasPrefix:@"<"] || [l hasPrefix:@"|"] || [l hasPrefix:@"---"] || [l hasPrefix:@"[!"]) continue;
        [para addObject:l];
    }
    if (para.count) *paragraph = [para componentsJoinedByString:@" "];
}

static NSDictionary *Project(LHHost *h) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableDictionary *p = [NSMutableDictionary new];
    NSMutableOrderedSet *configs = [NSMutableOrderedSet new];
    NSArray *configNames = @[@"vite.config.", @"next.config.", @"astro.config.", @"svelte.config.", @"nuxt.config.", @"remix.config.",
                             @"webpack.config.", @"tailwind.config.", @"tsconfig.json", @"docker-compose.yml", @"compose.yaml", @"Procfile",
                             @"manage.py", @"Gemfile", @"Cargo.toml", @"go.mod", @"wrangler.toml", @"netlify.toml", @"vercel.json",
                             @"turbo.json", @"pnpm-workspace.yaml", @"mix.exs", @"pyproject.toml", @"requirements.txt", @"playwright.config."];
    for (NSString *dir in Folders(h)) {
        NSString *pkg = [dir stringByAppendingPathComponent:@"package.json"];
        if (!p[@"name"] && [fm fileExistsAtPath:pkg]) {
            NSData *d = Head(pkg, 512 * 1024);
            NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
            if ([j isKindOfClass:NSDictionary.class]) {
                if (Clip(j[@"name"], 80)) p[@"name"] = Clip(j[@"name"], 80);
                if (Clip(j[@"description"], 300)) p[@"description"] = Clip(j[@"description"], 300);
                NSString *script = ScriptFor(h, j[@"scripts"]);
                if (script) p[@"script"] = Clip(script, 200);
            }
        }
        if (!p[@"readme"]) for (NSString *n in @[@"README.md", @"readme.md", @"Readme.md", @"README.markdown", @"README"]) {
            NSString *text = HeadText([dir stringByAppendingPathComponent:n], 16384);
            if (!text) continue;
            NSString *heading = nil, *para = nil;
            ReadmeIntro(text, &heading, &para);
            NSString *intro = heading && para ? [NSString stringWithFormat:@"%@: %@", heading, para] : heading ?: para;
            if (Clip(intro, 300)) p[@"readme"] = Clip(intro, 300);
            break;
        }
        NSString *mix = HeadText([dir stringByAppendingPathComponent:@"mix.exs"], 16384);
        if (mix && !p[@"app"]) {
            NSString *app = Match(mix, @"app:\\s*:(\\w+)");
            if (app) p[@"app"] = app;
            NSString *desc = Match(mix, @"description:\\s*\"([^\"]*)\"");
            if (!p[@"description"] && Clip(desc, 300)) p[@"description"] = Clip(desc, 300);
        }
        NSString *py = HeadText([dir stringByAppendingPathComponent:@"pyproject.toml"], 16384);
        if (py) {
            if (!p[@"name"] && Clip(Match(py, @"^name\\s*=\\s*\"([^\"]+)\""), 80)) p[@"name"] = Clip(Match(py, @"^name\\s*=\\s*\"([^\"]+)\""), 80);
            if (!p[@"description"] && Clip(Match(py, @"^description\\s*=\\s*\"([^\"]+)\""), 300)) p[@"description"] = Clip(Match(py, @"^description\\s*=\\s*\"([^\"]+)\""), 300);
        }
        // Only the names of config files, never their contents.
        for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil])
            for (NSString *c in configNames) if ([c hasSuffix:@"."] ? [f hasPrefix:c] : [f isEqualToString:c]) [configs addObject:f];
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"config/dev.exs"]]) [configs addObject:@"config/dev.exs"];
    }
    if (configs.count) p[@"configs"] = [configs.array subarrayWithRange:NSMakeRange(0, MIN(12, configs.count))];
    return p.count ? p : nil;
}

#pragma mark - Git

static NSDictionary *GitFacts(LHHost *h) {
    NSString *dir = h.repoRoot ?: h.cwd;
    if (!h.repo || !dir.length) return nil;
    NSMutableDictionary *g = [NSMutableDictionary new];
    NSArray *log = [Git(dir, @[@"log", @"-1", @"--format=%s%x1f%ct%x1f%an"], NULL) componentsSeparatedByString:@"\x1f"];
    if (log.count == 3) {
        g[@"last_commit"] = Clip(log[0], 160) ?: @"";
        g[@"last_commit_minutes_ago"] = MinutesAgo([NSDate dateWithTimeIntervalSince1970:[log[1] doubleValue]]);
        if (Clip(log[2], 60)) g[@"last_commit_author"] = Clip(log[2], 60);
    }
    int st;
    NSString *status = Git(dir, @[@"status", @"--porcelain"], &st);
    if (st == 0) g[@"dirty_files"] = @(status.length ? [status componentsSeparatedByString:@"\n"].count : 0);
    NSString *branch = h.branch;
    if (branch && ![branch hasPrefix:@"detached"]) {
        NSArray *up = [Git(dir, @[@"for-each-ref", @"--format=%(upstream:short)%1f%(upstream:track)", [@"refs/heads/" stringByAppendingString:branch]], NULL)
                       componentsSeparatedByString:@"\x1f"];
        if (up.count == 2 && [up[0] length]) {
            g[@"upstream"] = [up[1] containsString:@"gone"] ? @"gone" : up[0];
            NSString *ahead = Match(up[1], @"ahead (\\d+)"), *behind = Match(up[1], @"behind (\\d+)");
            g[@"ahead"] = @(ahead.integerValue); g[@"behind"] = @(behind.integerValue);
        } else g[@"upstream"] = @"none";
    }
    NSString *def = Git(dir, @[@"symbolic-ref", @"--quiet", @"--short", @"refs/remotes/origin/HEAD"], &st);
    if (st != 0 || !def.length) {
        def = nil;
        for (NSString *c in @[@"origin/main", @"origin/master", @"main", @"master"]) {
            Git(dir, @[@"rev-parse", @"--verify", @"--quiet", c], &st);
            if (st == 0) { def = c; break; }
        }
    }
    if (def) {
        g[@"default_branch"] = def;
        // Commits on this checkout that the default branch does not have. 0 means its work is merged, or it never had any.
        NSString *n = Git(dir, @[@"rev-list", @"--count", [def stringByAppendingString:@"..HEAD"]], &st);
        if (st == 0) g[@"commits_not_in_default"] = @(n.integerValue);
    }
    return g.count ? g : nil;
}

#pragma mark - Agent sessions

/// The first thing the user typed in a session log, skipping injected context such as AGENTS.md and command wrappers.
static NSString *FirstPrompt(NSString *head) {
    for (NSString *line in [head componentsSeparatedByString:@"\n"]) {
        if (![line containsString:@"\"user\""]) continue;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![j isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *m = [j[@"message"] isKindOfClass:NSDictionary.class] ? j[@"message"] : [j[@"payload"] isKindOfClass:NSDictionary.class] ? j[@"payload"] : nil;
        if (![m[@"role"] isEqual:@"user"]) continue;
        NSMutableArray *texts = [NSMutableArray new];
        if ([m[@"content"] isKindOfClass:NSString.class]) [texts addObject:m[@"content"]];
        else if ([m[@"content"] isKindOfClass:NSArray.class])
            for (NSDictionary *c in m[@"content"])
                if ([c isKindOfClass:NSDictionary.class] && [@[@"text", @"input_text"] containsObject:c[@"type"] ?: @""] && [c[@"text"] isKindOfClass:NSString.class]) [texts addObject:c[@"text"]];
        for (NSString *t in texts) {
            NSString *x = [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!x.length || [x hasPrefix:@"<"] || [x hasPrefix:@"Caveat:"] || [x containsString:@"AGENTS.md instructions"] || [x hasPrefix:@"# AGENTS.md"]) continue;
            return x;
        }
    }
    return nil;
}

/// The latest time between `after` and `by` that a session log line names one of the folders as a whole path:
/// followed by a slash, a quote or a space, so app-mid does not count for app. A session that only looked at the
/// folder after the server was running, or days before it started, did not start it.
static NSDate *NamedBetween(NSString *file, NSArray<NSString *> *folders, NSDate *after, NSDate *by) {
    NSData *all = [NSData dataWithContentsOfFile:file options:NSDataReadingMappedIfSafe error:nil];
    const char *bytes = all.bytes;
    NSDate *best = nil;
    NSData *nl = [@"\n" dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString *f in folders) for (NSString *end in @[@"/", @"\"", @" ", @"\\"]) {
        NSData *needle = [[f stringByAppendingString:end] dataUsingEncoding:NSUTF8StringEncoding];
        NSRange r = NSMakeRange(0, all.length);
        for (int hits = 0; hits < 200; hits++) {
            NSRange m = [all rangeOfData:needle options:0 range:r];
            if (m.location == NSNotFound) break;
            NSRange ls = [all rangeOfData:nl options:NSDataSearchBackwards range:NSMakeRange(0, m.location)];
            NSRange le = [all rangeOfData:nl options:0 range:NSMakeRange(m.location, all.length - m.location)];
            NSUInteger from = ls.location == NSNotFound ? 0 : ls.location + 1, to = le.location == NSNotFound ? all.length : le.location;
            // The line's own timestamp. Lines are JSON objects; the timestamp key sits near the start or the end.
            NSUInteger n = to - from;
            NSString *headPart = [[NSString alloc] initWithBytes:bytes + from length:MIN(n, 600) encoding:NSUTF8StringEncoding];
            NSString *tailPart = n > 600 ? [[NSString alloc] initWithBytes:bytes + to - 600 length:600 encoding:NSUTF8StringEncoding] : nil;
            NSDate *t = ISODate(Match(headPart, @"\"timestamp\":\\s*\"([^\"]+)\"") ?: Match(tailPart, @"\"timestamp\":\\s*\"([^\"]+)\""));
            if (t && [t compare:by] != NSOrderedDescending && [t compare:after] != NSOrderedAscending && (!best || [t compare:best] == NSOrderedDescending)) best = t;
            r = NSMakeRange(to, all.length - to);
            if (!r.length) break;
        }
    }
    return best;
}

/// A session counts when it was open when the server started: it began before the server and was written to after.
/// It runs in one of the server's folders, or it runs in a parent folder and named one of them in the half hour before the server started.
static void Consider(NSMutableArray *found, NSString *agent, NSString *file, LHHost *h, NSArray *folders, NSString *(^title)(NSString *head, NSString *file)) {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:file error:nil];
    NSDate *end = attrs.fileModificationDate;
    if (!end || [end timeIntervalSinceDate:h.started] < -60) return;
    NSString *head = HeadText(file, 256 * 1024);
    NSDate *start = ISODate(Match(head, @"\"timestamp\":\\s*\"([^\"]+)\""));
    if (!start || [start timeIntervalSinceDate:h.started] > 5) return;
    NSString *cwd = [Match(head, @"\"cwd\":\\s*\"([^\"]+)\"") stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
    BOOL exact = cwd && [folders containsObject:cwd];
    NSDate *named = exact ? start : NamedBetween(file, folders, [h.started dateByAddingTimeInterval:-1800], [h.started dateByAddingTimeInterval:120]);
    if (!named) return;
    NSMutableDictionary *s = [@{@"agent": agent, @"file": file, @"start": start, @"end": end, @"exact": @(exact), @"named": named} mutableCopy];
    NSString *t = title ? title(head, file) : nil;
    if (Clip(t, 200)) s[@"title"] = Clip(t, 200);
    if (Clip(FirstPrompt(head), 200)) s[@"first_prompt"] = Clip(FirstPrompt(head), 200);
    [found addObject:s];
}

/// The server's folders, then their parents up to the home folder, where agents are often started.
static NSArray<NSString *> *Ancestors(NSArray<NSString *> *folders) {
    NSMutableOrderedSet *a = [NSMutableOrderedSet orderedSetWithArray:folders];
    NSString *home = NSHomeDirectory();
    for (NSString *f in folders)
        for (NSString *d = f; d.length >= home.length && [d hasPrefix:home]; d = d.stringByDeletingLastPathComponent) [a addObject:d];
    return a.array;
}

static NSArray<NSString *> *Logs(NSString *dir, NSString *prefix) {
    NSMutableArray *l = [NSMutableArray new];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil])
        if ([f hasSuffix:@".jsonl"] && (!prefix || [f hasPrefix:prefix])) [l addObject:[dir stringByAppendingPathComponent:f]];
    return l;
}

static NSDictionary *Session(LHHost *h) {
    NSArray *folders = Folders(h);
    if (!folders.count || !h.started) return nil;
    NSArray *dirs = Ancestors(folders);
    NSMutableArray *found = [NSMutableArray new];
    NSString *home = NSHomeDirectory();

    // Claude Code: ~/.claude/projects/<folder with / and . as ->/<session>.jsonl. The title is the last ai-title line.
    NSString *(^claudeTitle)(NSString *, NSString *) = ^NSString *(NSString *head, NSString *file) {
        NSData *all = [NSData dataWithContentsOfFile:file options:NSDataReadingMappedIfSafe error:nil];
        NSUInteger from = all.length > 524288 ? all.length - 524288 : 0;
        NSString *tail = [[NSString alloc] initWithData:[all subdataWithRange:NSMakeRange(from, all.length - from)] encoding:NSUTF8StringEncoding];
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\"aiTitle\":\\s*\"((?:[^\"\\\\]|\\\\.)*)\"" options:0 error:nil];
        NSString *t = nil;
        for (NSString *s in @[tail ?: @"", head ?: @""]) {
            NSTextCheckingResult *m = [re matchesInString:s options:0 range:NSMakeRange(0, s.length)].lastObject;
            if (m) { t = [s substringWithRange:[m rangeAtIndex:1]]; break; }
        }
        return t;
    };
    NSString *claudeRoot = NSProcessInfo.processInfo.environment[@"CLAUDE_CONFIG_DIR"] ?: [home stringByAppendingPathComponent:@".claude"];
    for (NSString *d in dirs) {
        NSString *enc = [[d stringByReplacingOccurrencesOfString:@"/" withString:@"-"] stringByReplacingOccurrencesOfString:@"." withString:@"-"];
        for (NSString *f in Logs([[claudeRoot stringByAppendingPathComponent:@"projects"] stringByAppendingPathComponent:enc], nil))
            Consider(found, @"Claude Code", f, h, folders, claudeTitle);
    }

    // Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, titles in session_index.jsonl.
    NSString *codexHome = NSProcessInfo.processInfo.environment[@"CODEX_HOME"] ?: [home stringByAppendingPathComponent:@".codex"];
    NSMutableDictionary *names = [NSMutableDictionary new];
    NSString *index = [NSString stringWithContentsOfFile:[codexHome stringByAppendingPathComponent:@"session_index.jsonl"] encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [index componentsSeparatedByString:@"\n"]) {
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if ([j isKindOfClass:NSDictionary.class] && [j[@"id"] isKindOfClass:NSString.class] && [j[@"thread_name"] isKindOfClass:NSString.class]) names[j[@"id"]] = j[@"thread_name"];
    }
    NSDateFormatter *day = [NSDateFormatter new]; day.dateFormat = @"yyyy/MM/dd"; day.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    for (NSDate *d = [h.started dateByAddingTimeInterval:-7 * 86400]; [d timeIntervalSinceNow] < 86400; d = [d dateByAddingTimeInterval:86400])
        for (NSString *f in Logs([[codexHome stringByAppendingPathComponent:@"sessions"] stringByAppendingPathComponent:[day stringFromDate:d]], @"rollout-"))
            Consider(found, @"Codex", f, h, folders, ^NSString *(NSString *head, NSString *file) { return names[Match(head, @"\"id\":\\s*\"([^\"]+)\"") ?: @""]; });

    // pi: ~/.pi/agent/sessions/--<folder with / as ->--/<time>_<id>.jsonl.
    for (NSString *d in dirs) {
        NSString *enc = [NSString stringWithFormat:@"--%@--", [[d substringFromIndex:1] stringByReplacingOccurrencesOfString:@"/" withString:@"-"]];
        for (NSString *f in Logs([[home stringByAppendingPathComponent:@".pi/agent/sessions"] stringByAppendingPathComponent:enc], nil))
            Consider(found, @"pi", f, h, folders, nil);
    }

    // The closest match: a session in the server's own folder beats one that only names it; then the one that
    // started or named the folder closest to the server's start.
    [found sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        if (![a[@"exact"] isEqual:b[@"exact"]]) return [a[@"exact"] boolValue] ? NSOrderedAscending : NSOrderedDescending;
        return [b[@"named"] compare:a[@"named"]];
    }];
    NSDictionary *best = found.firstObject;
    if (!best) return nil;
    NSMutableDictionary *s = [NSMutableDictionary new];
    s[@"agent"] = best[@"agent"];
    if (best[@"title"]) s[@"title"] = best[@"title"];
    if (best[@"first_prompt"]) s[@"first_prompt"] = best[@"first_prompt"];
    s[@"started_minutes_ago"] = MinutesAgo(best[@"start"]);
    s[@"last_active_minutes_ago"] = MinutesAgo(best[@"end"]);
    s[@"match"] = [best[@"exact"] boolValue] ? @"session runs in this folder" : @"session in a parent folder named this folder just before the server started";
    if (![best[@"exact"] boolValue]) s[@"named_minutes_before_server"] = @((long)round([h.started timeIntervalSinceDate:best[@"named"]] / 60));
    s[@"file"] = [best[@"file"] stringByAbbreviatingWithTildeInPath];
    if (found.count > 1) s[@"other_matches"] = @(found.count - 1);
    return s;
}

#pragma mark - Cache

static NSDictionary *Read(LHHost *h) {
    NSMutableDictionary *i = [NSMutableDictionary new];
    i[@"project"] = Project(h);
    i[@"git"] = GitFacts(h);
    i[@"session"] = Session(h);
    return i;
}

NSDictionary *LHIntel(LHHost *h, BOOL wait) {
    static NSMutableDictionary *cache; static NSMutableSet *pending; static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; pending = [NSMutableSet new]; q = dispatch_queue_create("locohost.intel", DISPATCH_QUEUE_SERIAL); });
    if (![h.kind isEqualToString:@"dev"] || !h.key) return nil;
    NSDictionary *hit;
    @synchronized (cache) { hit = cache[h.key]; }
    BOOL stale = !hit || -[hit[@"at"] timeIntervalSinceNow] >= kIntelFresh;
    if (stale && wait) {
        NSDictionary *info = Read(h);
        @synchronized (cache) { cache[h.key] = @{@"at": NSDate.date, @"info": info}; }
        return info;
    }
    if (stale) @synchronized (cache) {
        if (![pending containsObject:h.key]) {
            [pending addObject:h.key];
            dispatch_async(q, ^{
                NSDictionary *info = Read(h);
                @synchronized (cache) { cache[h.key] = @{@"at": NSDate.date, @"info": info}; [pending removeObject:h.key]; }
            });
        }
    }
    return hit[@"info"];
}
