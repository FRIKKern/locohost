// LocoHost: every localhost on your Mac, what it is, who started it, and whether anyone still uses it.
// Menu bar app + CLI. Haiku or Luna on your own subscription reviews the list on a schedule and when something
// changes, and the mode decides what happens next: Idle only reports, Proactive stops obvious waste, and Eager
// stops every quiet server that cannot show evidence that someone still needs it.
#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>
#import <signal.h>
#import <netinet/in.h>
#import <UserNotifications/UserNotifications.h>
#import "Ports.h"
#import "Rules.h"
#import "Review.h"
#import "Intel.h"
#import "Where.h"

static NSString *const kReviewMinKey = @"locohost.reviewMinutes";   // default 60, 0 off
static NSString *const kModelKey     = @"locohost.model";           // default auto: Haiku, then Luna
static NSString *const kIdleMinKey   = @"locohost.idleMinutes";     // default 30
static NSString *const kProbeKey     = @"locohost.probeHTTP";       // default YES
static NSString *const kAskKey       = @"locohost.askBeforeClosing";// default YES
static NSString *const kForceKey     = @"locohost.forceMode";       // 0 leave, 1 ask (default), 2 force
static NSString *const kModeKey      = @"locohost.mode";            // idle | proactive | eager (default)

typedef NS_ENUM(NSInteger, LHForceMode) { LHForceNever = 0, LHForceAsk = 1, LHForceAlways = 2 };
static const NSTimeInterval kGrace = 6;          // seconds a server gets to stop after SIGTERM
static const double kMinConfidence = 0.6;        // an idle verdict below this does not count
static const double kSureConfidence = 0.8;       // an idle verdict this sure needs no second look
static const NSTimeInterval kSessionFresh = 60 * 60;    // an agent session active this recently keeps its server, in every mode
static const NSTimeInterval kReviewFresh = 3 * 3600;    // the modes act only on a review this recent
static const NSTimeInterval kEventGap = 10 * 60;        // reviews woken by events are at least this far apart

#pragma mark - Preferences

static CFStringRef const kDomain = CFSTR("no.guerrilla.locohost");
static id PrefGet(NSString *key) { return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, kDomain)); }
static void PrefSet(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, kDomain);
    CFPreferencesAppSynchronize(kDomain);
}
static BOOL PrefBool(NSString *key, BOOL dflt) { id v = PrefGet(key); return v ? [v boolValue] : dflt; }
static NSInteger PrefInt(NSString *key, NSInteger dflt) { id v = PrefGet(key); return v ? [v integerValue] : dflt; }
static NSString *Model(void) { id v = PrefGet(kModelKey); return [v isKindOfClass:NSString.class] && [v length] ? v : @"auto"; }
static NSInteger IdleMinutes(void) {
    NSString *env = NSProcessInfo.processInfo.environment[@"LOCOHOST_IDLE_MINUTES"];   // tests
    return env.length ? env.integerValue : PrefInt(kIdleMinKey, 30);
}
static LHForceMode ForceMode(void) { id v = PrefGet(kForceKey); return v ? (LHForceMode)[v integerValue] : LHForceAsk; }

/// What LocoHost does with what the review finds. Idle reports only. Proactive stops obvious waste: a server quiet for
/// six hours with no agent above it that the review calls idle with confidence. Eager puts the burden of proof on the
/// server: every quiet one that is not clearly idle goes to a judge, and stays only with a concrete fact that someone needs it.
typedef NS_ENUM(NSInteger, LHMode) { LHModeIdle = 0, LHModeProactive = 1, LHModeEager = 2 };
static NSArray<NSString *> *ModeNames(void) { return @[@"idle", @"proactive", @"eager"]; }
static NSString *ModeLabel(LHMode m) { return ModeNames()[m].capitalizedString; }
static NSInteger ModeFrom(NSString *s) { NSUInteger i = [ModeNames() indexOfObject:s.lowercaseString ?: @""]; return i == NSNotFound ? -1 : (NSInteger)i; }
static LHMode Mode(void) { id v = PrefGet(kModeKey); NSInteger m = [v isKindOfClass:NSString.class] ? ModeFrom(v) : -1; return m < 0 ? LHModeEager : (LHMode)m; }

/// Minutes from a test variable, else the default.
static NSTimeInterval EnvMinutes(NSString *key, double dflt) {
    NSString *env = NSProcessInfo.processInfo.environment[key];
    return (env.length ? env.doubleValue : dflt) * 60;
}
static NSTimeInterval MinUptime(void)    { return EnvMinutes(@"LOCOHOST_MIN_UPTIME_MINUTES", 30); }   // younger servers are never stopped by a mode
static NSTimeInterval ProactiveQuiet(void) { return EnvMinutes(@"LOCOHOST_PROACTIVE_MINUTES", 6 * 60); }

static NSString *Plural(NSInteger n, NSString *word) { return [NSString stringWithFormat:@"%ld %@%@", (long)n, word, n == 1 ? @"" : [word hasSuffix:@"s"] ? @"es" : @"s"]; }
static NSString *Pct(double v) { return [NSString stringWithFormat:@"%.0f%%", v]; }
static NSString *Tokens(NSInteger t) { return t >= 1000 ? [NSString stringWithFormat:@"%.1fk tokens", t / 1000.0] : [NSString stringWithFormat:@"%ld tokens", (long)t]; }

#pragma mark - Idle

/// The hosts Close Idle stops. All of these must hold:
/// it is a dev server, not protected, quiet for the idle threshold by local signals (no new connection, no CPU work),
/// the latest review called it idle with enough confidence, and nothing happened after that review.
/// An open but silent connection, such as a forgotten browser tab, does not keep a server alive on its own.
static NSArray<LHHost *> *Candidates(NSArray<LHHost *> *hosts, LHReview *review) {
    NSMutableArray *c = [NSMutableArray new];
    if (!review || review.error) return c;
    for (LHHost *h in hosts) {
        if (![h.kind isEqualToString:@"dev"] || h.isProtected || h.state != LHIdle) continue;
        LHVerdict *v = review.verdicts[h.key];
        if (![v.verdict isEqualToString:@"idle"] || v.confidence < kMinConfidence) continue;
        if (h.lastActive && [h.lastActive compare:review.at] == NSOrderedDescending) continue;
        [c addObject:h];
    }
    return c;
}

#pragma mark - Modes

/// keep.json: hosts the user asked every mode to leave alone until a time, by host key.
static NSString *KeepPath(void) { return [LHSupportDir() stringByAppendingPathComponent:@"keep.json"]; }
static NSMutableDictionary *KeepList(void) {
    NSData *d = [NSData dataWithContentsOfFile:KeepPath()];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    NSMutableDictionary *k = [j isKindOfClass:NSMutableDictionary.class] ? j : [NSMutableDictionary new];
    for (NSString *key in k.allKeys) if ([k[key] doubleValue] < NSDate.date.timeIntervalSince1970) [k removeObjectForKey:key];
    return k;
}
static NSDate *KeptUntil(LHHost *h) { id t = KeepList()[h.key]; return t ? [NSDate dateWithTimeIntervalSince1970:[t doubleValue]] : nil; }
/// hours 0 clears it.
static void SetKeep(LHHost *h, double hours) {
    NSMutableDictionary *k = KeepList();
    if (hours > 0) k[h.key] = @(NSDate.date.timeIntervalSince1970 + hours * 3600); else [k removeObjectForKey:h.key];
    [NSFileManager.defaultManager createDirectoryAtPath:LHSupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSJSONSerialization dataWithJSONObject:k options:NSJSONWritingPrettyPrinted error:nil] writeToFile:KeepPath() atomically:YES];
}

static double SessionMinutes(NSDictionary *intel) {
    id m = intel[@"session"][@"last_active_minutes_ago"];
    return m ? [m doubleValue] : -1;
}

/// Why a host stays whatever the mode, or nil when the mode may decide. wait reads the investigation now (the CLI).
static NSString *MustKeep(LHHost *h, LHReview *r, LHMode mode, BOOL wait) {
    if (![h.kind isEqualToString:@"dev"]) return @"not a dev server";
    if (h.isProtected) return @"protected";
    NSDate *kept = KeptUntil(h);
    if (kept) return [NSString stringWithFormat:@"kept by you for %@ more", LHDuration(kept.timeIntervalSinceNow)];
    if (h.state != LHIdle) return h.lastActive ? [NSString stringWithFormat:@"used %@ ago", LHDuration(-h.lastActive.timeIntervalSinceNow)] : @"in use";
    if (-h.started.timeIntervalSinceNow < MinUptime()) return [NSString stringWithFormat:@"started only %@ ago", LHDuration(-h.started.timeIntervalSinceNow)];
    if (!r) return @"no review yet";
    if (r.error) return @"the last review failed";
    if (-r.at.timeIntervalSinceNow > kReviewFresh) return [NSString stringWithFormat:@"the last review is %@ old", LHDuration(-r.at.timeIntervalSinceNow)];
    if (h.lastActive && [h.lastActive compare:r.at] == NSOrderedDescending) return @"used after the last review";
    if (!r.verdicts[h.key]) return @"not in the last review";
    double session = SessionMinutes(LHIntel(h, wait));
    if (session >= 0 && session * 60 < kSessionFresh) return [NSString stringWithFormat:@"its agent session was active %@ ago", LHDuration(session * 60)];
    if (mode != LHModeEager && h.agent && !h.orphaned) return [NSString stringWithFormat:@"%@ still runs above it", h.agent];
    return nil;
}

/// For every dev host: stop or keep under this mode, and the one-line reason. Idle mode stops nothing.
static NSArray<NSDictionary *> *Plan(NSArray<LHHost *> *hosts, LHReview *r, LHMode mode, BOOL wait) {
    NSMutableArray *plan = [NSMutableArray new];
    for (LHHost *h in hosts) {
        if (![h.kind isEqualToString:@"dev"]) continue;
        NSString *why = MustKeep(h, r, mode, wait);
        BOOL stop = NO;
        LHVerdict *v = r.verdicts[h.key];
        NSString *quiet = LHDuration(-(h.lastActive ?: h.firstSeen).timeIntervalSinceNow);
        BOOL idle = [v.verdict isEqualToString:@"idle"];
        if (why) {
        } else if (mode == LHModeIdle) {
            why = idle ? [NSString stringWithFormat:@"Idle mode only reports; the review calls it idle: %@", v.reason] : @"Idle mode only reports";
        } else if (mode == LHModeProactive) {
            if (-(h.lastActive ?: h.firstSeen).timeIntervalSinceNow < ProactiveQuiet())
                why = [NSString stringWithFormat:@"quiet %@; Proactive waits %@", quiet, LHDuration(ProactiveQuiet())];
            else if (idle && v.confidence >= kSureConfidence) { stop = YES; why = [NSString stringWithFormat:@"quiet %@: %@", quiet, v.reason]; }
            else why = [NSString stringWithFormat:@"the review says %@ (%.0f%%)", v.verdict, v.confidence * 100];
        } else if (v.judged) {
            if (idle && v.confidence >= kMinConfidence) { stop = YES; why = [NSString stringWithFormat:@"quiet %@, no evidence to keep it: %@", quiet, v.reason]; }
            else why = idle ? [NSString stringWithFormat:@"the judge was not sure (%.0f%%)", v.confidence * 100]
                            : [NSString stringWithFormat:@"evidence: %@", v.keepEvidence.length ? v.keepEvidence : v.reason];
        } else if (idle && v.confidence >= kSureConfidence) {
            stop = YES; why = [NSString stringWithFormat:@"quiet %@: %@", quiet, v.reason];
        } else if (v.keepEvidence.length) {
            why = [@"evidence: " stringByAppendingString:v.keepEvidence];
        } else if (r.judgeError && idle && v.confidence >= kMinConfidence) {
            stop = YES; why = [NSString stringWithFormat:@"quiet %@: %@ (the judge failed)", quiet, v.reason];
        } else {
            why = r.judgeError ? [@"the judge failed: " stringByAppendingString:r.judgeError] : @"not judged yet";
        }
        [plan addObject:@{@"host": h, @"stop": @(stop), @"why": why}];
    }
    return plan;
}

/// The plan by host key, as the menu uses it. Not static, so a snapshot harness can build the same card.
NSDictionary *LHMenuPlan(NSArray<LHHost *> *hosts, LHReview *r) {
    NSMutableDictionary *plan = [NSMutableDictionary new];
    for (NSDictionary *p in Plan(hosts, r, Mode(), NO)) plan[((LHHost *)p[@"host"]).key] = p;
    return plan;
}

/// The hosts the Eager judge looks at: quiet, free to decide, and not already clearly idle or judged.
static NSArray<LHHost *> *JudgeSubjects(NSArray<LHHost *> *hosts, LHReview *r, BOOL wait) {
    NSMutableArray *j = [NSMutableArray new];
    for (LHHost *h in hosts) {
        if (MustKeep(h, r, LHModeEager, wait)) continue;
        LHVerdict *v = r.verdicts[h.key];
        if (v.judged || ([v.verdict isEqualToString:@"idle"] && v.confidence >= kSureConfidence)) continue;
        [j addObject:h];
    }
    return j;
}

/// A full review: the first pass, then in Eager mode the judge for the hosts that need one. Blocks.
static LHReview *RunReview(NSArray<LHHost *> *hosts, LHScanner *s, NSString *model, LHMode mode, NSString *trigger) {
    LHReview *r = [LHReviewer review:hosts scanner:s model:model];
    r.mode = ModeNames()[mode]; r.trigger = trigger;
    if (!r.error && mode == LHModeEager) [LHReviewer judge:JudgeSubjects(hosts, r, YES) review:r scanner:s model:model];
    return r;
}

static NSString *StateMark(LHHost *h, LHReview *r) {
    if (h.state == LHActive) return @"●";                 // ● in use now
    if ([r.verdicts[h.key].verdict isEqualToString:@"idle"] && h.state == LHIdle) return @"◇";   // ◇ idle, confirmed
    return h.state == LHRecent ? @"◐" : @"○";        // ◐ recent, ○ quiet
}

static NSString *StateWords(LHHost *h) {
    NSString *who = h.clients.count ? [h.clients componentsJoinedByString:@", "] : h.connections ? Plural(h.connections, @"connection") : nil;
    if (h.state == LHActive) return h.newConnections ? [NSString stringWithFormat:@"requests from %@", who ?: @"a client"] : @"working (CPU)";
    NSDate *q = h.lastActive ?: h.firstSeen;
    NSString *quiet = [NSString stringWithFormat:@"quiet %@%@", LHDuration(-q.timeIntervalSinceNow), h.lastActive ? @"" : @"+"];
    return who ? [NSString stringWithFormat:@"%@, open in %@", quiet, who] : quiet;
}

static NSString *Wh(double joules) { return [NSString stringWithFormat:joules >= 3600 ? @"%.1f Wh" : @"%.2f Wh", joules / 3600]; }

/// What a host burned since it was last used: "since last use 3h: 12m CPU · 0.40 Wh · holds 905 MB".
static NSString *WasteWords(LHHost *h) {
    NSDate *since = h.lastActive ?: h.firstSeen;
    NSMutableArray *p = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"%@ CPU", LHDuration(h.idleCPUSeconds)]];
    if (h.energyJoules > 0) [p addObject:Wh(h.idleJoules)];
    [p addObject:[NSString stringWithFormat:@"holds %@", LHFormatBytes(h.memory)]];
    return [NSString stringWithFormat:@"%@ %@: %@", h.lastActive ? @"since last use" : @"since LocoHost first saw it", LHDuration(-since.timeIntervalSinceNow),
            [p componentsJoinedByString:@" · "]];
}

/// The agent session that was open when the server started, or the plain fact that none was found.
static NSString *SessionWords(NSDictionary *s) {
    if (!s) return @"no agent session found";
    NSString *t = s[@"title"] ?: s[@"first_prompt"];
    return [NSString stringWithFormat:@"%@ session%@, last active %@ ago", s[@"agent"], t ? [NSString stringWithFormat:@" \"%@\"", t] : @"",
            LHDuration([s[@"last_active_minutes_ago"] doubleValue] * 60)];
}

static NSString *GitWords(NSDictionary *g, LHHost *h) {
    if (!g) return nil;
    NSMutableArray *p = [NSMutableArray new];
    if (h.branch) [p addObject:[@"branch " stringByAppendingString:h.branch]];
    if (g[@"last_commit"]) [p addObject:[NSString stringWithFormat:@"last commit \"%@\" %@ ago%@", g[@"last_commit"], LHDuration([g[@"last_commit_minutes_ago"] doubleValue] * 60),
                                         g[@"last_commit_author"] ? [@" by " stringByAppendingString:g[@"last_commit_author"]] : @""]];
    if (g[@"dirty_files"]) [p addObject:[g[@"dirty_files"] integerValue] ? Plural([g[@"dirty_files"] integerValue], @"uncommitted file") : @"clean"];
    if ([g[@"upstream"] isEqual:@"gone"]) [p addObject:@"remote branch deleted"];
    else if ([g[@"upstream"] isEqual:@"none"]) [p addObject:@"never pushed"];
    else if (g[@"upstream"]) [p addObject:[NSString stringWithFormat:@"%@ ahead, %@ behind %@", g[@"ahead"], g[@"behind"], g[@"upstream"]]];
    if (g[@"commits_not_in_default"]) [p addObject:[NSString stringWithFormat:@"%@ not in %@", Plural([g[@"commits_not_in_default"] integerValue], @"commit"), g[@"default_branch"]]];
    return [p componentsJoinedByString:@" · "];
}

/// The model's sentence when there is one, else what LocoHost found itself.
static NSString *WhatWords(LHHost *h, LHVerdict *v, NSDictionary *intel) {
    if (v.what.length) return v.what;
    NSDictionary *p = intel[@"project"];
    NSString *d = p[@"description"] ?: p[@"readme"];
    return d ? [NSString stringWithFormat:@"%@ %@: %@", p[@"name"] ?: h.project, h.framework, d] : nil;
}
static NSString *HowWords(LHHost *h, LHVerdict *v, NSDictionary *intel) {
    if (v.how.length) return v.how;
    NSString *script = intel[@"project"][@"script"];
    return [NSString stringWithFormat:@"%@%@, started by %@", h.command, script ? [NSString stringWithFormat:@" (script %@)", script] : @"", h.launcher.length ? h.launcher : @"unknown"];
}

#pragma mark - Stopping

/// The processes a stop signals: the server's tree, then the package manager wrappers above it.
static NSArray<NSNumber *> *Targets(LHHost *h) {
    NSMutableArray *t = [h.treePids mutableCopy];
    if (h.wrapperPid > 1) [t addObject:@(h.wrapperPid)];
    [t removeObject:@(getpid())]; [t removeObject:@1];
    return t;
}

static NSArray<LHHost *> *StillRunning(NSArray<LHHost *> *hosts, NSTimeInterval wait) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:wait];
    NSMutableArray *left = [hosts mutableCopy];
    do {
        [left filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(LHHost *h, id _) { return [LHScanner alive:h]; }]];
        if (!left.count) break;
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
    } while ([deadline timeIntervalSinceNow] > 0);
    return left;
}

/// closed.json: what LocoHost stopped, newest first, with the command that starts it again.
static NSString *ClosedPath(void) { return [LHSupportDir() stringByAppendingPathComponent:@"closed.json"]; }
static NSArray<NSDictionary *> *Closed(void) {
    NSData *d = [NSData dataWithContentsOfFile:ClosedPath()];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    return [j isKindOfClass:NSArray.class] ? j : @[];
}
static void SetClosed(NSArray *all) {
    [NSFileManager.defaultManager createDirectoryAtPath:LHSupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSJSONSerialization dataWithJSONObject:all ?: @[] options:NSJSONWritingPrettyPrinted error:nil] writeToFile:ClosedPath() atomically:YES];
}

/// by names who stopped it: nil for the user, or the mode. why is the reason per host key.
static void RememberClosed(NSArray<LHHost *> *hosts, NSString *by, NSDictionary<NSString *, NSString *> *why) {
    NSMutableArray *all = [Closed() mutableCopy];
    for (LHHost *h in hosts)
        [all insertObject:@{@"at": @(NSDate.date.timeIntervalSince1970), @"port": @(h.port), @"project": h.project,
                            @"framework": h.framework, @"restart": h.restartCommand, @"by": by ?: @"you", @"why": why[h.key] ?: @""} atIndex:0];
    while (all.count > 20) [all removeLastObject];
    SetClosed(all);
}

/// SIGTERM and a grace period. Returns the hosts that are still running.
static NSArray<LHHost *> *StopHostsBy(NSArray<LHHost *> *hosts, NSTimeInterval grace, NSString *by, NSDictionary *why) {
    NSMutableArray *live = [NSMutableArray new];
    for (LHHost *h in hosts) if ([LHScanner alive:h]) [live addObject:h];   // never signal a reused pid
    RememberClosed(live, by, why);
    for (LHHost *h in live) for (NSNumber *p in Targets(h)) kill(p.intValue, SIGTERM);
    return StillRunning(live, grace);
}

static NSArray<LHHost *> *StopHosts(NSArray<LHHost *> *hosts, NSTimeInterval grace) { return StopHostsBy(hosts, grace, nil, nil); }

/// Starts a stopped server again with its recorded command, through a login shell so PATH matches the user's terminal.
/// Output goes to restart.log in the support folder. Returns NO with *error set when the shell could not start.
static BOOL Restart(NSString *command, NSString **error) {
    NSString *log = [LHSupportDir() stringByAppendingPathComponent:@"restart.log"];
    [NSFileManager.defaultManager createDirectoryAtPath:LHSupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
    if (![NSFileManager.defaultManager fileExistsAtPath:log]) [NSData.data writeToFile:log atomically:YES];
    NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:log];
    [out seekToEndOfFile];
    [out writeData:[[NSString stringWithFormat:@"\n%@ $ %@\n", NSDate.date, command] dataUsingEncoding:NSUTF8StringEncoding]];
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/zsh"];
    t.arguments = @[@"-lc", command];
    t.standardInput = NSFileHandle.fileHandleWithNullDevice; t.standardOutput = out; t.standardError = out;
    NSError *e = nil;
    if ([t launchAndReturnError:&e]) return YES;
    *error = e.localizedDescription;
    return NO;
}

/// SIGKILL. Whatever the server had in memory is lost.
static NSArray<LHHost *> *KillHosts(NSArray<LHHost *> *hosts) {
    for (LHHost *h in hosts) if ([LHScanner alive:h]) for (NSNumber *p in Targets(h)) kill(p.intValue, SIGKILL);
    return StillRunning(hosts, 2);
}

/// Carries out the mode's plan on freshly sampled hosts. SIGTERM first; SIGKILL only when the user's setting is
/// Force Stop It or force is set. Never asks: a server that ignores SIGTERM is left running and said so.
/// Returns what was done, for review.json and the notification.
static NSArray<NSDictionary *> *AutoStop(NSArray<LHHost *> *hosts, LHReview *r, LHMode mode, BOOL wait, BOOL force) {
    if (mode == LHModeIdle) return @[];
    NSMutableArray *targets = [NSMutableArray new]; NSMutableDictionary *why = [NSMutableDictionary new];
    for (NSDictionary *p in Plan(hosts, r, mode, wait)) if ([p[@"stop"] boolValue]) { [targets addObject:p[@"host"]]; why[[p[@"host"] key]] = p[@"why"]; }
    if (!targets.count) return @[];
    NSArray *left = StopHostsBy(targets, kGrace, ModeLabel(mode), why);
    if (left.count && (force || ForceMode() == LHForceAlways)) left = KillHosts(left);
    NSMutableArray *actions = [NSMutableArray new];
    for (LHHost *h in targets)
        [actions addObject:@{@"port": @(h.port), @"project": h.project, @"framework": h.framework, @"memoryBytes": @(h.memory),
                             @"why": why[h.key], @"stopped": @(![left containsObject:h]), @"at": @(NSDate.date.timeIntervalSince1970)}];
    return actions;
}

#pragma mark - CLI

static void PrintJSON(id obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    printf("%s\n", [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding].UTF8String);
}

static NSString *Cut(NSString *s, NSUInteger n) { return s.length > n ? [[s substringToIndex:n - 1] stringByAppendingString:@"…"] : (s ?: @""); }

/// Lines of at most n characters, broken at spaces, for text shown as menu headers.
static NSArray<NSString *> *Wrap(NSString *s, NSUInteger n) {
    NSMutableArray *lines = [NSMutableArray new]; NSMutableString *line = [NSMutableString new];
    for (NSString *w in [s componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (!w.length) continue;
        if (line.length && line.length + 1 + w.length > n) { [lines addObject:[line copy]]; [line setString:@""]; }
        if (line.length) [line appendString:@" "];
        [line appendString:w];
    }
    if (line.length) [lines addObject:line];
    return lines;
}

static void PrintHosts(NSArray<LHHost *> *hosts, LHReview *r) {
    printf("%-3s%-7s%-16s%-38s%-9s%6s %9s  %-26s%s\n", "", "port", "what", "project", "up", "cpu", "memory", "state", "started by");
    for (LHHost *h in hosts) {
        NSString *proj = h.branch ? [NSString stringWithFormat:@"%@ · %@", h.project, h.branch] : h.project;
        printf("%-3s%-7ld%-16s%-38s%-9s%5.1f%% %9s  %-26s%s\n", StateMark(h, r).UTF8String, (long)h.port, Cut(h.framework, 15).UTF8String,
               Cut(proj, 37).UTF8String, LHDuration(-h.started.timeIntervalSinceNow).UTF8String, h.cpuPercent,
               LHFormatBytes(h.memory).UTF8String, Cut(StateWords(h), 25).UTF8String, h.launcher.UTF8String);
        LHVerdict *v = r.verdicts[h.key];
        if (v) printf("       %s %s (%.0f%%): %s\n", LHModelLabel(r.model).UTF8String, v.verdict.UTF8String, v.confidence * 100, v.reason.UTF8String);
    }
}

static NSDictionary *HostJSON(LHHost *h, LHReview *r) {
    NSMutableDictionary *j = [h.json mutableCopy];
    LHVerdict *v = r.verdicts[h.key];
    if (v) j[@"review"] = @{@"verdict": v.verdict, @"confidence": @(v.confidence), @"about": v.about ?: @"", @"reason": v.reason ?: @"",
                            @"model": r.model ?: @"", @"at": @(r.at.timeIntervalSince1970)};
    return j;
}

static LHHost *FindHost(NSArray<LHHost *> *hosts, NSString *arg) {
    NSInteger n = arg.integerValue;
    for (LHHost *h in hosts) if ([h.ports containsObject:@(n)]) return h;
    for (LHHost *h in hosts) if (h.pid == n) return h;
    return nil;
}

static BOOL Confirm(NSString *q) {
    printf("%s [y/N] ", q.UTF8String); fflush(stdout);
    char buf[8] = {0};
    return fgets(buf, sizeof buf, stdin) && (buf[0] == 'y' || buf[0] == 'Y');
}

/// Stops hosts from the CLI: SIGTERM, then SIGKILL with --force. Exit 0 all stopped, 3 some still running.
static int CLIStop(NSArray<LHHost *> *targets, BOOL force) {
    NSArray *left = StopHosts(targets, kGrace);
    NSInteger forced = 0;
    if (left.count && force) {
        for (LHHost *h in left) printf("force stopping :%ld %s\n", (long)h.port, h.framework.UTF8String);
        forced = left.count; left = KillHosts(left); forced -= left.count;
    }
    for (LHHost *h in left) printf("still running%s: :%ld %s (pid %d)\n", force ? "" : " (ignored SIGTERM; use --force)", (long)h.port, h.framework.UTF8String, h.pid);
    printf("stopped %lu of %lu%s\n", (unsigned long)(targets.count - left.count), (unsigned long)targets.count,
           forced ? [NSString stringWithFormat:@", %ld by force", (long)forced].UTF8String : "");
    return left.count ? 3 : 0;
}

static int Usage(void) {
    fprintf(stderr,
        "usage: locohost <command> [options]\n"
        "  list                  every localhost: port, what, project, uptime, cost, state, who started it (default)\n"
        "  who <port>            the process on a port, its folder, branch and command, and who is connected\n"
        "  ready <port>          wait until the port accepts connections; exit 0 ready, 1 timed out\n"
        "  free [port]           the first free port at or above port (default 3000)\n"
        "  explain <port>        what it is, how it runs, why it is there and what it wastes, with every fact found\n"
        "  where <port>          the cmux tab, tmux pane, terminal tab or app it runs in (--go brings it forward)\n"
        "  waste                 what each server burned since it was last used, and duplicates\n"
        "  review                ask the model which localhosts are in use; in Eager mode the judge looks again\n"
        "  summary               what is going on, in the model's words, and what the mode would do\n"
        "  auto                  one round of the mode: stop what it decides to stop (--dry-run shows it, --review reviews first)\n"
        "  mode [name]           show or set the mode: idle (report only), proactive (obvious waste), eager (default)\n"
        "  idle                  what Close Idle would stop right now\n"
        "  close <port|pid>      stop one server: SIGTERM, then SIGKILL with --force\n"
        "  close-idle            stop every confirmed idle server\n"
        "  open <port>           open it in the browser\n"
        "  stopped               what LocoHost stopped, with the command to start each again\n"
        "  restart <port>        start the server LocoHost last stopped on that port again\n"
        "  keep <port> [hours]   no mode stops it for this many hours (default 4, 0 clears)\n"
        "  rules                 print the rules file path\n"
        "options:\n"
        "  --json                machine-readable output\n"
        "  --yes                 do not ask\n"
        "  --force               SIGKILL servers that ignore SIGTERM\n"
        "  --timeout <s>         ready: give up after this many seconds (default 60)\n"
        "  --http                ready: also wait for an HTTP answer below 500\n"
        "  --model <alias>       review: auto (Haiku, then Luna), haiku, sonnet, opus, luna or a full model name (setting: locohost.model)\n"
        "  --review              close-idle: run a review first\n"
        "  --port <port>         close-idle: only this port\n"
        "  --mode <name>         review, summary, auto: use this mode instead of the setting\n"
        "  --dry-run             auto: show the plan, stop nothing\n");
    return 2;
}

static NSInteger HTTPStatus(NSInteger port) {
    __block NSInteger status = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.timeoutIntervalForRequest = 2;
    NSURLSession *s = [NSURLSession sessionWithConfiguration:cfg];
    [[s dataTaskWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/", (long)port]]
      completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        if ([resp isKindOfClass:NSHTTPURLResponse.class]) status = ((NSHTTPURLResponse *)resp).statusCode;
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    [s invalidateAndCancel];
    return status;
}

static BOOL PortFree(NSInteger port) {
    if (LHPortListening(port)) return NO;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = {0}; a.sin_family = AF_INET; a.sin_port = htons(port); a.sin_addr.s_addr = htonl(INADDR_ANY);
    BOOL ok = bind(fd, (struct sockaddr *)&a, sizeof(a)) == 0;
    close(fd);
    return ok;
}

static int RunCLI(int argc, const char **argv) {
    NSMutableArray<NSString *> *args = [NSMutableArray new];
    for (int i = 1; i < argc; i++) [args addObject:@(argv[i])];
    NSString *cmd = args.firstObject ?: @"list";
    BOOL json = [args containsObject:@"--json"], yes = [args containsObject:@"--yes"], force = [args containsObject:@"--force"];
    NSString *(^opt)(NSString *) = ^NSString *(NSString *name) {
        NSUInteger i = [args indexOfObject:name];
        return (i != NSNotFound && i + 1 < args.count) ? args[i + 1] : nil;
    };
    NSString *arg1 = args.count > 1 && ![args[1] hasPrefix:@"--"] ? args[1] : nil;

    if ([cmd isEqualToString:@"rules"]) { printf("%s\n", LHRules.shared.fileURL.path.UTF8String); return 0; }
    if ([cmd isEqualToString:@"mode"]) {
        if (arg1) {
            if (ModeFrom(arg1) < 0) return Usage();
            PrefSet(kModeKey, ModeNames()[ModeFrom(arg1)]);
        }
        printf("%s\n", ModeNames()[Mode()].UTF8String);
        return 0;
    }
    NSInteger modeOpt = opt(@"--mode") ? ModeFrom(opt(@"--mode")) : Mode();
    if (modeOpt < 0) return Usage();
    LHMode mode = (LHMode)modeOpt;
    if ([cmd isEqualToString:@"stopped"]) {
        if (json) { PrintJSON(Closed()); return 0; }
        for (NSDictionary *c in Closed())
            printf(":%-6s %-14s %s ago by %s%s\n        %s\n", [c[@"port"] description].UTF8String, [c[@"framework"] UTF8String],
                   LHDuration(NSDate.date.timeIntervalSince1970 - [c[@"at"] doubleValue]).UTF8String, [c[@"by"] ?: @"you" UTF8String],
                   [c[@"why"] length] ? [NSString stringWithFormat:@": %@", c[@"why"]].UTF8String : "", [c[@"restart"] UTF8String]);
        return 0;
    }
    if ([cmd isEqualToString:@"restart"]) {
        if (!arg1) return Usage();
        for (NSDictionary *c in Closed()) {
            if ([c[@"port"] integerValue] != arg1.integerValue) continue;
            if (LHPortListening(arg1.integerValue)) { fprintf(stderr, ":%s is already taken\n", arg1.UTF8String); return 1; }
            NSString *e = nil;
            if (!Restart(c[@"restart"], &e)) { fprintf(stderr, "could not restart: %s\n", e.UTF8String); return 1; }
            printf("restarting :%s: %s\n", arg1.UTF8String, [c[@"restart"] UTF8String]);
            return 0;
        }
        fprintf(stderr, "LocoHost has not stopped anything on :%s\n", arg1.UTF8String);
        return 1;
    }
    if ([cmd isEqualToString:@"free"]) {
        for (NSInteger p = arg1 ? arg1.integerValue : 3000; p < 65536; p++) if (PortFree(p)) { printf("%ld\n", (long)p); return 0; }
        return 1;
    }
    if ([cmd isEqualToString:@"ready"]) {
        if (!arg1) return Usage();
        NSInteger port = arg1.integerValue;
        double timeout = opt(@"--timeout") ? opt(@"--timeout").doubleValue : 60;
        BOOL http = [args containsObject:@"--http"];
        NSDate *start = NSDate.date;
        while (-start.timeIntervalSinceNow < timeout) {
            if (LHPortListening(port)) {
                NSInteger st = http ? HTTPStatus(port) : 0;
                if (!http || (st > 0 && st < 500)) {
                    printf("ready :%ld after %.1fs%s\n", (long)port, -start.timeIntervalSinceNow, http ? [NSString stringWithFormat:@" (HTTP %ld)", (long)st].UTF8String : "");
                    return 0;
                }
            }
            [NSThread sleepForTimeInterval:0.25];
        }
        fprintf(stderr, "not ready: nothing %s on :%ld after %.0fs\n", http ? "answered HTTP" : "accepted a connection", (long)port, timeout);
        return 1;
    }
    if ([cmd isEqualToString:@"open"]) {
        if (!arg1) return Usage();
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://localhost:%@", arg1]]];
        return 0;
    }
    if (![@[@"list", @"who", @"explain", @"where", @"waste", @"review", @"summary", @"auto", @"idle", @"close", @"close-idle", @"keep"] containsObject:cmd]) return Usage();

    LHScanner *s = [LHScanner new];
    s.idleSeconds = IdleMinutes() * 60;
    [s sample]; [NSThread sleepForTimeInterval:1.0]; [s sample];   // two samples for CPU%
    if (PrefBool(kProbeKey, YES) && ![cmd hasPrefix:@"close"] && ![@[@"auto", @"where"] containsObject:cmd]) {
        __block BOOL done = NO;
        [s probeHosts:^{ done = YES; }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
        while (!done && deadline.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    LHReview *review = [LHReview load];

    if ([cmd isEqualToString:@"list"]) {
        BOOL all = [args containsObject:@"--all"];
        if (json) {
            NSMutableArray *o = [NSMutableArray new], *ig = [NSMutableArray new];
            for (LHHost *h in s.hosts) [o addObject:HostJSON(h, review)];
            for (LHIgnored *i in s.ignored) [ig addObject:@{@"pid": @(i.pid), @"name": i.name, @"ports": i.ports}];
            NSMutableArray *plan = [NSMutableArray new];
            for (NSDictionary *p in Plan(s.hosts, review, mode, YES)) [plan addObject:@{@"key": ((LHHost *)p[@"host"]).key, @"port": @(((LHHost *)p[@"host"]).port), @"stop": p[@"stop"], @"why": p[@"why"]}];
            PrintJSON(@{@"hosts": o, @"ignored": ig, @"idleMinutes": @(IdleMinutes()), @"mode": ModeNames()[mode], @"plan": plan,
                        @"watchingSince": @(s.watchingSince.timeIntervalSince1970), @"candidates": [Candidates(s.hosts, review) valueForKey:@"key"]});
            return 0;
        }
        if (!s.hosts.count) { printf("no localhosts running\n"); return 0; }
        PrintHosts(s.hosts, review);
        uint64_t mem = 0; double cpu = 0; NSInteger active = 0, idle = 0;
        for (LHHost *h in s.hosts) { mem += h.memory; cpu += h.cpuPercent; active += h.state == LHActive; idle += h.state == LHIdle; }
        printf("\n%s: %ld in use now, %ld quiet over %ldm · %s CPU · %s · watching for %s\n", Plural(s.hosts.count, @"localhost").UTF8String,
               (long)active, (long)idle, (long)IdleMinutes(), Pct(cpu).UTF8String, LHFormatBytes(mem).UTF8String, LHDuration(-s.watchingSince.timeIntervalSinceNow).UTF8String);
        if (review) printf("last review: %s ago by %s%s\n", LHDuration(-review.at.timeIntervalSinceNow).UTF8String, LHModelLabel(review.model).UTF8String,
                           review.error ? [NSString stringWithFormat:@" (failed: %@)", review.error].UTF8String : "");
        if (all && s.ignored.count) {
            printf("\nignored (macOS and apps, never touched):\n");
            for (LHIgnored *i in s.ignored) printf("  %-24s pid %-7d %s\n", i.name.UTF8String, i.pid, [[i.ports valueForKey:@"stringValue"] componentsJoinedByString:@", "].UTF8String);
        }
        return 0;
    }

    if ([cmd isEqualToString:@"who"]) {
        if (!arg1) return Usage();
        LHHost *h = FindHost(s.hosts, arg1);
        if (!h) {
            for (LHIgnored *i in s.ignored) if ([i.ports containsObject:@(arg1.integerValue)]) { printf(":%s is held by %s (pid %d), which LocoHost ignores\n", arg1.UTF8String, i.name.UTF8String, i.pid); return 0; }
            printf(":%s is %s\n", arg1.UTF8String, LHPortListening(arg1.integerValue) ? "taken by a process LocoHost cannot read (another user or root)" : "free");
            return 1;
        }
        if (json) { PrintJSON(HostJSON(h, review)); return 0; }
        printf(":%ld  %s  pid %d  (%s)\n", (long)h.port, h.framework.UTF8String, h.pid, h.kind.UTF8String);
        printf("  ports      %s on %s\n", [[h.ports valueForKey:@"stringValue"] componentsJoinedByString:@", "].UTF8String, h.bind.UTF8String);
        printf("  folder     %s\n", h.cwd.stringByAbbreviatingWithTildeInPath.UTF8String);
        if (h.repo) printf("  repo       %s%s%s\n", h.repo.UTF8String, h.branch ? [NSString stringWithFormat:@" on %@", h.branch].UTF8String : "",
                           h.worktree ? [NSString stringWithFormat:@", worktree %@", h.worktree].UTF8String : "");
        printf("  command    %s\n", h.command.UTF8String);
        printf("  started by %s\n", h.launcher.UTF8String);
        printf("  up         %s · CPU %.1f%% now, %s total · %s in %s\n", LHDuration(-h.started.timeIntervalSinceNow).UTF8String, h.cpuPercent,
               LHDuration(h.cpuSeconds).UTF8String, LHFormatBytes(h.memory).UTF8String, Plural(h.processCount, @"process").UTF8String);
        printf("  clients    %s%s\n", h.clients.count ? [h.clients componentsJoinedByString:@", "].UTF8String : h.connections ? Plural(h.connections, @"connection").UTF8String : "none now",
               h.newConnections ? [NSString stringWithFormat:@" (%ld new)", (long)h.newConnections].UTF8String : "");
        printf("  state      %s\n", StateWords(h).UTF8String);
        if (h.title || h.httpStatus) printf("  page       %s (HTTP %ld)\n", (h.title ?: @"no title").UTF8String, (long)h.httpStatus);
        LHVerdict *v = review.verdicts[h.key];
        if (v) printf("  review     %s %s (%.0f%%), %s ago: %s\n", LHModelLabel(review.model).UTF8String, v.verdict.UTF8String, v.confidence * 100,
                      LHDuration(-review.at.timeIntervalSinceNow).UTF8String, v.reason.UTF8String);
        NSDictionary *intel = LHIntel(h, YES);
        if (WhatWords(h, v, intel)) printf("  what       %s\n", WhatWords(h, v, intel).UTF8String);
        if ([h.kind isEqualToString:@"dev"]) printf("  why        %s\n", (v.why.length ? v.why : SessionWords(intel[@"session"])).UTF8String);
        printf("  waste      %s\n", WasteWords(h).UTF8String);
        if (h.duplicates.count) printf("  duplicate  same folder and branch as :%s\n", [[h.duplicates valueForKey:@"stringValue"] componentsJoinedByString:@", :"].UTF8String);
        NSDictionary *where = LHWhere(h, YES);
        if (where) printf("  where      %s\n", [where[@"label"] UTF8String]);
        if (h.isProtected) printf("  protected  Close Idle never stops it\n");
        return 0;
    }

    if ([cmd isEqualToString:@"where"]) {
        if (!arg1) return Usage();
        LHHost *h = FindHost(s.hosts, arg1);
        if (!h) { fprintf(stderr, "no localhost on %s\n", arg1.UTF8String); return 1; }
        NSDictionary *w = LHWhere(h, YES);
        if (json) { PrintJSON(w ?: @{}); return w ? 0 : 1; }
        if (!w) { printf(":%ld: no terminal or app found\n", (long)h.port); return 1; }
        printf(":%ld  %s\n", (long)h.port, [w[@"label"] UTF8String]);
        if ([args containsObject:@"--go"]) {
            NSString *e = nil;
            if (!LHGoTo(w, &e) && e) { fprintf(stderr, "%s\n", e.UTF8String); return 1; }
        }
        return 0;
    }

    if ([cmd isEqualToString:@"explain"]) {
        if (!arg1) return Usage();
        LHHost *h = FindHost(s.hosts, arg1);
        if (!h) { fprintf(stderr, "no localhost on %s\n", arg1.UTF8String); return 1; }
        NSDictionary *intel = LHIntel(h, YES) ?: @{};
        LHVerdict *v = review.verdicts[h.key];
        if (json) {
            NSMutableDictionary *j = [HostJSON(h, review) mutableCopy];
            j[@"intel"] = intel; j[@"waste"] = LHWasteFacts(h); j[@"where"] = LHWhere(h, YES) ?: NSNull.null;
            PrintJSON(j); return 0;
        }
        printf(":%ld  %s  %s  (pid %d, %s)\n\n", (long)h.port, h.framework.UTF8String, h.project.UTF8String, h.pid, h.kind.UTF8String);
        NSString *what = WhatWords(h, v, intel);
        printf("  What      %s\n", (what ?: @"no project description found").UTF8String);
        printf("  How       %s\n", HowWords(h, v, intel).UTF8String);
        if ([h.kind isEqualToString:@"dev"]) printf("  Why       %s\n", (v.why.length ? v.why : SessionWords(intel[@"session"])).UTF8String);
        printf("  Waste     %s\n", (v.waste.length ? v.waste : WasteWords(h)).UTF8String);
        if (v) printf("  Verdict   %s says %s (%.0f%%), %s ago: %s\n", LHModelLabel(review.model).UTF8String, v.verdict.UTF8String, v.confidence * 100,
                      LHDuration(-review.at.timeIntervalSinceNow).UTF8String, v.reason.UTF8String);
        if (v.recommendation.length) printf("  Advice    %s\n", v.recommendation.UTF8String);
        if (!v.what.length) printf("            (no review with explanations yet: run `locohost review`)\n");

        printf("\nWhat LocoHost found\n");
        NSDictionary *p = intel[@"project"];
        if (p[@"name"] || p[@"description"]) printf("  project   %s%s\n", [p[@"name"] ?: h.project UTF8String], p[@"description"] ? [NSString stringWithFormat:@": %@", p[@"description"]].UTF8String : "");
        if (p[@"script"]) printf("  script    %s\n", [p[@"script"] UTF8String]);
        if (p[@"app"]) printf("  mix app   %s\n", [p[@"app"] UTF8String]);
        if (p[@"readme"]) printf("  readme    %s\n", [p[@"readme"] UTF8String]);
        if ([p[@"configs"] count]) printf("  configs   %s\n", [p[@"configs"] componentsJoinedByString:@", "].UTF8String);
        if (!p) printf("  project   no package.json, README, mix.exs or pyproject.toml in its folders\n");
        printf("  command   %s\n  started   %s, %s ago\n", h.command.UTF8String, h.launcher.UTF8String, LHDuration(-h.started.timeIntervalSinceNow).UTF8String);
        if (GitWords(intel[@"git"], h)) printf("  git       %s\n", GitWords(intel[@"git"], h).UTF8String);
        NSDictionary *se = intel[@"session"];
        printf("  session   %s\n", SessionWords(se).UTF8String);
        if (se) {
            printf("            started %s ago · %s%s\n", LHDuration([se[@"started_minutes_ago"] doubleValue] * 60).UTF8String, [se[@"match"] UTF8String],
                   se[@"other_matches"] ? [NSString stringWithFormat:@" · %@ other sessions also match", se[@"other_matches"]].UTF8String : "");
            if (se[@"first_prompt"]) printf("            first prompt: %s\n", [se[@"first_prompt"] UTF8String]);
            printf("            %s\n", [se[@"file"] UTF8String]);
        }
        printf("  waste     %s\n", WasteWords(h).UTF8String);
        if (h.energyJoules > 0) printf("            %s and %s CPU since it started\n", Wh(h.energyJoules).UTF8String, LHDuration(h.cpuSeconds).UTF8String);
        if (h.duplicates.count) printf("  duplicate same folder and branch as :%s\n", [[h.duplicates valueForKey:@"stringValue"] componentsJoinedByString:@", :"].UTF8String);
        printf("  clients   %s\n  state     %s\n", h.clients.count ? [h.clients componentsJoinedByString:@", "].UTF8String : "none now", StateWords(h).UTF8String);
        return 0;
    }

    if ([cmd isEqualToString:@"waste"]) {
        NSArray *dev = [s.hosts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind == 'dev'"]];
        dev = [dev sortedArrayUsingComparator:^NSComparisonResult(LHHost *a, LHHost *b) {
            double wa = a.state == LHIdle ? -[(a.lastActive ?: a.firstSeen) timeIntervalSinceNow] * a.memory : 0, wb = b.state == LHIdle ? -[(b.lastActive ?: b.firstSeen) timeIntervalSinceNow] * b.memory : 0;
            return wa > wb ? NSOrderedAscending : wa < wb ? NSOrderedDescending : [@(a.port) compare:@(b.port)];
        }];
        double cpu = 0, joules = 0; uint64_t mem = 0; NSInteger idle = 0;
        for (LHHost *h in dev) if (h.state == LHIdle) { idle++; cpu += h.idleCPUSeconds; joules += h.idleJoules; mem += h.memory; }
        BOOL energy = [[dev valueForKeyPath:@"@max.energyJoules"] doubleValue] > 0;
        if (json) {
            NSMutableArray *o = [NSMutableArray new];
            for (LHHost *h in dev) [o addObject:@{@"key": h.key, @"port": @(h.port), @"project": h.project, @"state": h.state == LHIdle ? @"idle" : h.state == LHRecent ? @"recent" : @"active",
                                                  @"waste": LHWasteFacts(h), @"duplicates": h.duplicates ?: @[]}];
            PrintJSON(@{@"hosts": o, @"idle": @{@"count": @(idle), @"cpuSeconds": @(round(cpu)), @"energyWh": energy ? @(round(joules / 3.6) / 1000) : NSNull.null, @"memoryBytes": @(mem)}});
            return 0;
        }
        if (!dev.count) { printf("no dev servers running\n"); return 0; }
        printf("%-3s%-7s%-14s%-38s%-10s%9s%10s%10s\n", "", "port", "what", "project", "unused", "cpu", "energy", "memory");
        for (LHHost *h in dev)
            printf("%-3s%-7ld%-14s%-38s%-10s%9s%10s%10s%s\n", StateMark(h, review).UTF8String, (long)h.port, Cut(h.framework, 13).UTF8String, Cut(h.project, 37).UTF8String,
                   h.state == LHActive ? "now" : LHDuration(-(h.lastActive ?: h.firstSeen).timeIntervalSinceNow).UTF8String, LHDuration(h.idleCPUSeconds).UTF8String,
                   energy ? Wh(h.idleJoules).UTF8String : "-", LHFormatBytes(h.memory).UTF8String,
                   h.duplicates.count ? [NSString stringWithFormat:@"  duplicate of :%@", [[h.duplicates valueForKey:@"stringValue"] componentsJoinedByString:@", :"]].UTF8String : "");
        printf("\n%s quiet over %ldm hold %s and burned %s CPU%s since they were last used\n", Plural(idle, @"server").UTF8String, (long)IdleMinutes(),
               LHFormatBytes(mem).UTF8String, LHDuration(cpu).UTF8String, energy ? [NSString stringWithFormat:@" and %@", Wh(joules)].UTF8String : "");
        return 0;
    }

    if ([cmd isEqualToString:@"review"] || ([@[@"close-idle", @"auto"] containsObject:cmd] && [args containsObject:@"--review"])) {
        NSString *model = opt(@"--model") ?: Model();
        if (!json) { fprintf(stderr, "reviewing %s with %s…\n", Plural(s.hosts.count, @"localhost").UTF8String, LHModelLabel(model).UTF8String); }
        review = RunReview(s.hosts, s, model, mode, @"manual");
        [review save];
        if (review.error) { fprintf(stderr, "review failed: %s\n", review.error.UTF8String); return 1; }
        if (review.note && !json) fprintf(stderr, "%s, so %s answered\n", review.note.UTF8String, LHModelLabel(review.model).UTF8String);
        if (review.judgeError && !json) fprintf(stderr, "the Eager judge failed: %s\n", review.judgeError.UTF8String);
        if ([cmd isEqualToString:@"review"]) {
            if (json) {
                NSMutableArray *o = [NSMutableArray new];
                for (LHHost *h in s.hosts) [o addObject:HostJSON(h, review)];
                PrintJSON(@{@"hosts": o, @"model": review.model ?: model, @"note": review.note ?: NSNull.null, @"tokens": @(review.tokens), @"seconds": @(review.seconds),
                            @"candidates": [Candidates(s.hosts, review) valueForKey:@"key"]});
                return 0;
            }
            for (LHHost *h in s.hosts) {
                LHVerdict *v = review.verdicts[h.key];
                printf("%-3s:%-6ld %-7s %3.0f%%  %s\n         %s\n", StateMark(h, review).UTF8String, (long)h.port, (v.verdict ?: @"-").UTF8String,
                       v.confidence * 100, (v.about ?: h.framework).UTF8String, (v.reason ?: @"no verdict").UTF8String);
            }
            printf("\n%s in %.0fs · %s · %ld confirmed idle now\n", LHModelLabel(review.model).UTF8String, review.seconds, Tokens(review.tokens).UTF8String,
                   (long)Candidates(s.hosts, review).count);
            if (review.summary.length) printf("\n%s\n", review.summary.UTF8String);
            return 0;
        }
    }

    if ([cmd isEqualToString:@"summary"] || [cmd isEqualToString:@"auto"]) {
        BOOL dry = [cmd isEqualToString:@"summary"] || [args containsObject:@"--dry-run"];
        NSArray<LHHost *> *scope = s.hosts;
        if (opt(@"--port")) scope = [scope filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(LHHost *h, id _) { return [h.ports containsObject:@(opt(@"--port").integerValue)]; }]];
        NSArray *plan = Plan(scope, review, mode, YES);
        NSArray *actions = dry ? @[] : AutoStop(scope, review, mode, YES, force);
        if (!dry && review && actions.count) { review.actions = actions; [review save]; }
        if (json) {
            NSMutableArray *o = [NSMutableArray new];
            for (NSDictionary *p in plan) [o addObject:@{@"key": ((LHHost *)p[@"host"]).key, @"port": @(((LHHost *)p[@"host"]).port), @"project": ((LHHost *)p[@"host"]).project, @"stop": p[@"stop"], @"why": p[@"why"]}];
            PrintJSON(@{@"mode": ModeNames()[mode], @"summary": review.summary ?: NSNull.null, @"plan": o, @"actions": actions,
                        @"reviewAt": review ? @(review.at.timeIntervalSince1970) : NSNull.null, @"trigger": review.trigger ?: NSNull.null});
            return 0;
        }
        if ([cmd isEqualToString:@"summary"]) {
            if (review.summary.length) printf("%s\n\n", review.summary.UTF8String);
            else printf("no summary yet: run `locohost review`\n\n");
            if (review) printf("review %s ago by %s%s\n", LHDuration(-review.at.timeIntervalSinceNow).UTF8String, LHModelLabel(review.model).UTF8String,
                               review.trigger ? [NSString stringWithFormat:@", woken by %@", review.trigger].UTF8String : "");
        }
        printf("%s mode%s:\n", ModeLabel(mode).UTF8String, dry && [cmd isEqualToString:@"auto"] ? ", dry run" : "");
        for (NSDictionary *p in plan) {
            LHHost *h = p[@"host"];
            printf("  %-5s :%-6ld %-14s %-36s %s\n", [p[@"stop"] boolValue] ? "stop" : "keep", (long)h.port, Cut(h.framework, 14).UTF8String,
                   Cut(h.project, 36).UTF8String, [p[@"why"] UTF8String]);
        }
        if (!plan.count) printf("  no dev servers running\n");
        for (NSDictionary *a in actions)
            printf("%s :%s %s\n", [a[@"stopped"] boolValue] ? "stopped" : "still running (ignored SIGTERM)", [a[@"port"] description].UTF8String, [a[@"project"] UTF8String]);
        return 0;
    }

    if ([cmd isEqualToString:@"idle"] || [cmd isEqualToString:@"close-idle"]) {
        NSArray<LHHost *> *c = Candidates(s.hosts, review);
        if (opt(@"--port")) c = [c filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(LHHost *h, id _) { return [h.ports containsObject:@(opt(@"--port").integerValue)]; }]];
        if (json && [cmd isEqualToString:@"idle"]) {
            NSMutableArray *o = [NSMutableArray new];
            for (LHHost *h in c) [o addObject:HostJSON(h, review)];
            PrintJSON(@{@"candidates": o, @"reviewAt": review ? @(review.at.timeIntervalSince1970) : NSNull.null});
            return 0;
        }
        if (!review) printf("no review yet: run `locohost review` or wait for the scheduled one\n");
        uint64_t mem = 0;
        for (LHHost *h in c) {
            mem += h.memory;
            printf("  :%-6ld %-14s %-36s up %-8s %9s  %s\n", (long)h.port, Cut(h.framework, 14).UTF8String, Cut(h.project, 36).UTF8String,
                   LHDuration(-h.started.timeIntervalSinceNow).UTF8String, LHFormatBytes(h.memory).UTF8String, review.verdicts[h.key].reason.UTF8String);
        }
        if (!c.count) { printf("nothing confirmed idle\n"); return 0; }
        if ([cmd isEqualToString:@"idle"]) { printf("%s confirmed idle · %s\n", Plural(c.count, @"server").UTF8String, LHFormatBytes(mem).UTF8String); return 0; }
        if (!yes && !Confirm([NSString stringWithFormat:@"Stop %@ (%@)?%@", Plural(c.count, @"server"), LHFormatBytes(mem), force ? @" Servers that ignore SIGTERM will be KILLED." : @""])) { printf("aborted\n"); return 1; }
        return CLIStop(c, force);
    }

    if ([cmd isEqualToString:@"keep"]) {
        if (!arg1) return Usage();
        LHHost *h = FindHost(s.hosts, arg1);
        if (!h) { fprintf(stderr, "no localhost on %s\n", arg1.UTF8String); return 1; }
        double hours = args.count > 2 && ![args[2] hasPrefix:@"--"] ? args[2].doubleValue : 4;
        SetKeep(h, hours);
        if (hours > 0) printf("no mode stops :%ld %s for %s\n", (long)h.port, h.framework.UTF8String, LHDuration(hours * 3600).UTF8String);
        else printf(":%ld %s is up to the mode again\n", (long)h.port, h.framework.UTF8String);
        return 0;
    }

    if ([cmd isEqualToString:@"close"]) {
        if (!arg1) return Usage();
        LHHost *h = FindHost(s.hosts, arg1);
        if (!h) { fprintf(stderr, "no localhost on %s\n", arg1.UTF8String); return 1; }
        if (!yes && !Confirm([NSString stringWithFormat:@"Stop :%ld %@ in %@ (pid %d)?", (long)h.port, h.framework, h.project, h.pid])) { printf("aborted\n"); return 1; }
        return CLIStop(@[h], force);
    }
    return Usage();
}

#pragma mark - App

@interface LocoHost : NSObject <NSApplicationDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) LHScanner *scanner;
@property (strong) LHReview *review;
@property (strong) NSTimer *timer;
@property BOOL reviewing;
@property NSInteger ticks;
// What wakes a review besides the schedule: a new server, a long uptime, memory pressure, sustained load.
@property (strong) NSMutableSet<NSString *> *known;                        // host keys seen, so a new one stands out
@property (strong) NSMutableDictionary<NSString *, NSNumber *> *ageMark;   // per host: how many uptime marks it has passed
@property (copy) NSString *pending;                                          // the event waiting to wake a review
@property (strong) NSDate *lastEvent;                                        // when an event last woke one
@property NSInteger loadTicks;                                               // samples in a row with load above the core count
@property BOOL learned;                                                      // the servers running at launch are known
@property (strong) dispatch_source_t pressure;
@property (strong) NSDictionary<NSString *, NSDictionary *> *plan;   // by host key, built when the menu opens
@property (copy) NSString *prefix;                                    // the start every dev server's name shares, left out of rows
@end

@implementation LocoHost

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    self.scanner = [LHScanner new];
    self.review = [LHReview load];
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(handleClick:);
    self.statusItem.button.imagePosition = NSImageLeft;
    [self.statusItem.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    self.known = [NSMutableSet new]; self.ageMark = [NSMutableDictionary new];
    self.pressure = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0, DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, dispatch_get_main_queue());
    dispatch_source_set_event_handler(self.pressure, ^{
        self.pending = dispatch_source_get_data(self.pressure) & DISPATCH_MEMORYPRESSURE_CRITICAL ? @"critical memory pressure" : @"memory pressure";
    });
    dispatch_resume(self.pressure);
    [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:UNAuthorizationOptionAlert completionHandler:^(BOOL ok, NSError *e) {}];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    self.timer.tolerance = 1;
    [self tick];
}

/// Notes the events that should wake a review: a dev server that has run for two minutes and was not there before,
/// one that passes a day, three days or a week of uptime, and load above the core count for half a minute.
/// The first sample only learns what is already running.
- (void)watchEvents {
    BOOL first = !self.learned;
    self.learned = YES;
    static const double marks[] = {86400, 3 * 86400, 7 * 86400};
    for (LHHost *h in self.scanner.hosts) {
        if (![h.kind isEqualToString:@"dev"]) continue;
        double up = -h.started.timeIntervalSinceNow;
        NSInteger passed = 0; while (passed < 3 && up >= marks[passed]) passed++;
        if (![self.known containsObject:h.key]) {
            if (first || up >= 120) {
                [self.known addObject:h.key]; self.ageMark[h.key] = @(passed);
                if (!first) self.pending = [NSString stringWithFormat:@"new server :%ld %@", (long)h.port, h.framework];
            }
            continue;
        }
        if (passed > [self.ageMark[h.key] integerValue]) {
            self.ageMark[h.key] = @(passed);
            self.pending = [NSString stringWithFormat:@":%ld up %@", (long)h.port, LHDuration(marks[passed - 1])];
        }
    }
    double load[1] = {0};
    if (getloadavg(load, 1) == 1 && load[0] > NSProcessInfo.processInfo.activeProcessorCount) self.loadTicks++; else self.loadTicks = 0;
    if (self.loadTicks == 6) self.pending = [NSString stringWithFormat:@"high load %.1f", load[0]];
}

- (void)tick {
    self.scanner.idleSeconds = IdleMinutes() * 60;
    [self.scanner sample];
    for (LHHost *h in self.scanner.hosts) LHIntel(h, NO);   // reads project, git and sessions in the background, five-minute cache
    if (self.ticks % 6 == 0) LHWhereRefresh(self.scanner.hosts);   // which cmux tab, tmux pane or app each one runs in
    if (self.ticks++ % 6 == 0 && PrefBool(kProbeKey, YES)) [self.scanner probeHosts:nil];   // every 30 s, each host at most every 5 min
    [self watchEvents];
    NSInteger every = PrefInt(kReviewMinKey, 60);
    BOOL hosts = self.scanner.hosts.count > 0;
    if (every > 0 && !self.reviewing && hosts && (!self.review || -self.review.at.timeIntervalSinceNow >= every * 60))
        [self reviewBecause:@"schedule"];
    else if (every > 0 && self.pending && !self.reviewing && hosts && (!self.lastEvent || -self.lastEvent.timeIntervalSinceNow >= kEventGap)) {
        self.lastEvent = NSDate.date;
        [self reviewBecause:self.pending];
    }
    [self updateButton];
}

- (void)updateButton {
    NSArray *dev = [self.scanner.hosts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind != 'other'"]];
    NSInteger idle = Candidates(self.scanner.hosts, self.review).count;
    NSImage *img = [NSImage imageWithSystemSymbolName:idle ? @"server.rack" : @"network" accessibilityDescription:@"LocoHost"];
    img = [img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular]];
    img.template = YES;
    self.statusItem.button.image = img;
    NSString *t = idle ? [NSString stringWithFormat:@" %lu · %ld idle", (unsigned long)dev.count, (long)idle] : [NSString stringWithFormat:@" %lu", (unsigned long)dev.count];
    self.statusItem.button.attributedTitle = [[NSAttributedString alloc] initWithString:t attributes:@{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular]}];
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"LocoHost: %@, %ld confirmed idle", Plural(dev.count, @"localhost"), (long)idle];
}

#pragma mark Review

- (void)reviewNow { [self reviewBecause:@"manual"]; }

/// Reviews in the background, then lets the mode act on fresh samples.
- (void)reviewBecause:(NSString *)trigger {
    if (self.reviewing) return;
    self.reviewing = YES; self.pending = nil;
    NSArray *hosts = self.scanner.hosts; LHScanner *s = self.scanner; NSString *model = Model(); LHMode mode = Mode();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        LHReview *r = RunReview(hosts, s, model, mode, trigger);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.review = r; self.reviewing = NO;
            [self.scanner sample];   // re-check right before acting
            r.actions = AutoStop(self.scanner.hosts, r, mode, NO, NO);
            [r save];
            [self notify:r.actions mode:mode];
            [self updateButton];
        });
    });
}

- (void)notify:(NSArray<NSDictionary *> *)actions mode:(LHMode)mode {
    if (!actions.count) return;
    uint64_t mem = 0; NSMutableArray *lines = [NSMutableArray new];
    for (NSDictionary *a in actions) {
        if ([a[@"stopped"] boolValue]) mem += [a[@"memoryBytes"] unsignedLongLongValue];
        [lines addObject:[NSString stringWithFormat:@":%@ %@%@", a[@"port"], a[@"project"], [a[@"stopped"] boolValue] ? @"" : @" (still running)"]];
    }
    UNMutableNotificationContent *c = [UNMutableNotificationContent new];
    c.title = [NSString stringWithFormat:@"%@ stopped %@, %@ freed", ModeLabel(mode), Plural(actions.count, @"server"), LHFormatBytes(mem)];
    c.body = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\nRecently Stopped keeps each restart command."];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:[UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString content:c trigger:nil]
                                                         withCompletionHandler:nil];
}

#pragma mark Menu

static NSMenuItem *Item(NSMenu *m, NSString *t, SEL a, id target, BOOL on) {
    NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:t action:a keyEquivalent:@""];
    i.target = target; i.state = on ? NSControlStateValueOn : NSControlStateValueOff; [m addItem:i]; return i;
}
static NSMenuItem *Header(NSMenu *m, NSString *t) { NSMenuItem *i = Item(m, t, NULL, nil, NO); i.enabled = NO; return i; }
static NSMenuItem *Sub(NSMenu *m, NSString *t, NSMenu *sub) { NSMenuItem *i = Item(m, t, NULL, nil, NO); i.submenu = sub; return i; }

/// One calm line per host: a colored dot, the port, what it is, then memory and uptime in aligned columns.
/// Everything else lives in the row's submenu.
- (NSAttributedString *)rowTitle:(LHHost *)h {
    NSColor *dot = h.state == LHActive ? NSColor.systemGreenColor : [StateMark(h, self.review) isEqualToString:@"◇"] ? NSColor.systemOrangeColor
                 : h.state == LHRecent ? NSColor.systemYellowColor : NSColor.tertiaryLabelColor;
    NSFont *f = [NSFont menuFontOfSize:0], *mono = [NSFont monospacedDigitSystemFontOfSize:f.pointSize weight:NSFontWeightRegular];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.tabStops = @[[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:18 options:@{}],
                    [[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:74 options:@{}],
                    [[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentRight location:400 options:@{}],
                    [[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentRight location:450 options:@{}]];
    NSDictionary *base = @{NSFontAttributeName: f, NSParagraphStyleAttributeName: ps};
    NSMutableDictionary *dim = [base mutableCopy]; dim[NSForegroundColorAttributeName] = NSColor.secondaryLabelColor; dim[NSFontAttributeName] = mono;
    NSMutableDictionary *dotA = [base mutableCopy]; dotA[NSForegroundColorAttributeName] = dot;
    NSMutableDictionary *portA = [base mutableCopy]; portA[NSFontAttributeName] = mono;
    NSString *name = [h.kind isEqualToString:@"dev"] ? [NSString stringWithFormat:@"%@  %@", h.framework, h.worktree ?: h.project] : h.framework;
    NSString *up = [LHDuration(-h.started.timeIntervalSinceNow) componentsSeparatedByString:@" "].firstObject;
    NSMutableAttributedString *t = [NSMutableAttributedString new];
    [t appendAttributedString:[[NSAttributedString alloc] initWithString:@"●" attributes:dotA]];
    [t appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"\t:%ld", (long)h.port] attributes:portA]];
    [t appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\t" stringByAppendingString:Cut(name, 38)] attributes:base]];
    [t appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"\t%@\t%@", LHFormatBytes(h.memory), up] attributes:dim]];
    return t;
}

/// A menu line with a gray tail, such as "Review Now   3m ago · Haiku".
static NSAttributedString *Titled(NSString *title, NSString *tail) {
    NSFont *f = [NSFont menuFontOfSize:0];
    NSMutableAttributedString *t = [[NSMutableAttributedString alloc] initWithString:title attributes:@{NSFontAttributeName: f}];
    if (tail.length) [t appendAttributedString:[[NSAttributedString alloc] initWithString:title.length ? [@"   " stringByAppendingString:tail] : tail
                                                                              attributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: NSColor.secondaryLabelColor}]];
    return t;
}

/// The menu's newer parts: subtitles, badges, section headers and the inline palette need macOS 14.4.
static BOOL ModernMenu(void) { if (@available(macOS 14.4, *)) return YES; return NO; }

static NSString *ShortName(LHHost *h) { return [h.kind isEqualToString:@"dev"] ? (h.worktree ?: h.project) : h.framework; }

/// The top of the menu: memory in large type, one line of counts, and the state bar.
static NSView *MenuHeader(NSArray<LHHost *> *hosts, LHReview *r, NSString *line, double cpu) {
    CGFloat w = 330;
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, w, 62)];
    uint64_t mem = 0; for (LHHost *h in hosts) mem += h.memory;
    NSTextField *n = [NSTextField labelWithString:LHFormatBytes(mem)];
    n.font = [NSFont monospacedDigitSystemFontOfSize:22 weight:NSFontWeightSemibold]; n.frame = NSMakeRect(14, 24, 200, 28); [v addSubview:n];
    NSTextField *c = [NSTextField labelWithString:[NSString stringWithFormat:@"%@ CPU", Pct(cpu)]];
    c.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium]; c.textColor = NSColor.secondaryLabelColor;
    c.alignment = NSTextAlignmentRight; c.frame = NSMakeRect(w - 134, 30, 120, 16); [v addSubview:c];
    NSTextField *l = [NSTextField labelWithString:line];
    l.font = [NSFont systemFontOfSize:12]; l.textColor = NSColor.secondaryLabelColor; l.lineBreakMode = NSLineBreakByTruncatingTail;
    l.frame = NSMakeRect(14, 8, w - 28, 15); [v addSubview:l];
    return v;
}

/// Wrapped, readable text of a fixed width and at most `lines` lines (0 for no limit), sized to fit.
static NSTextField *Para(NSString *text, NSFont *font, NSColor *color, CGFloat width, NSInteger lines) {
    NSTextField *t = [NSTextField wrappingLabelWithString:text ?: @""];
    t.font = font; t.textColor = color; t.preferredMaxLayoutWidth = width;
    t.maximumNumberOfLines = lines; t.cell.truncatesLastVisibleLine = YES;
    CGFloat h = [t.cell cellSizeForBounds:NSMakeRect(0, 0, width, 4000)].height;
    if (lines > 0) h = MIN(h, ceil(lines * (font.ascender - font.descender + font.leading) + 1));
    [t.widthAnchor constraintEqualToConstant:width].active = YES; [t.heightAnchor constraintEqualToConstant:h].active = YES;
    t.frame = NSMakeRect(0, 0, width, h);
    return t;
}
static NSAttributedString *Rich(NSString *bold, NSColor *boldColor, NSString *rest, CGFloat size) {
    NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:bold attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:size weight:NSFontWeightSemibold], NSForegroundColorAttributeName: boldColor}];
    if (rest.length) [a appendAttributedString:[[NSAttributedString alloc] initWithString:[@" " stringByAppendingString:rest] attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:size], NSForegroundColorAttributeName: NSColor.labelColor}]];
    return a;
}

/// Text inside a menu at a readable width, in the normal text color rather than the gray of a disabled item.
static NSMenuItem *TextItem(NSString *text, NSInteger lines) {
    NSTextField *t = Para(text, [NSFont systemFontOfSize:12.5], NSColor.secondaryLabelColor, 302, lines);
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 330, t.frame.size.height + 10)];
    t.frame = NSMakeRect(14, 5, 302, t.frame.size.height); [box addSubview:t];
    NSMenuItem *i = [NSMenuItem new]; i.view = box;
    return i;
}

static NSString *Sentence(NSString *s) {
    if (!s.length) return @"";
    s = [[s substringToIndex:1].uppercaseString stringByAppendingString:[s substringFromIndex:1]];
    return [s hasSuffix:@"."] ? s : [s stringByAppendingString:@"."];
}

static void Section(NSMenu *m, NSString *title) {
    if (@available(macOS 14.0, *)) [m addItem:[NSMenuItem sectionHeaderWithTitle:title]];
    else Header(m, title);
}

/// Why a host is still running, in plain words: a short colored head, then the reason and what happens next.
- (NSArray *)statusFor:(LHHost *)h {
    NSDictionary *p = self.plan[h.key];
    if ([h.kind isEqualToString:@"service"]) return @[@"Shared service.", NSColor.secondaryLabelColor, @"No mode stops services such as databases; stop it yourself if you want it gone."];
    if (!p) return @[@"Other listener.", NSColor.secondaryLabelColor, @"High-port listeners are listed only, and no mode stops them."];
    NSString *why = p[@"why"];
    if ([p[@"stop"] boolValue]) return @[@"Stops at the next review.", NSColor.systemOrangeColor, Sentence(Cut(why, 220))];
    LHMode mode = Mode();
    if (mode == LHModeIdle) return @[@"Staying on.", NSColor.systemGreenColor, @"Idle mode only reports. Close Idle or Stop are up to you."];
    NSString *next = @"";
    if ([why hasPrefix:@"used "] || [why isEqualToString:@"in use"])
        next = [NSString stringWithFormat:@" %@ looks again after %@ of quiet.", ModeLabel(mode), LHDuration(IdleMinutes() * 60)];
    else if ([why hasPrefix:@"started only"]) next = @" New servers get 30 minutes.";
    else if ([why hasPrefix:@"its agent session"]) next = @" The agent may still need it.";
    else if ([why hasPrefix:@"used after the last review"]) next = @" The next review looks again.";
    else if ([why hasPrefix:@"not judged yet"]) { why = @"not judged yet"; next = @" The judge looks at it in the next review."; }
    else if ([why hasPrefix:@"evidence: "]) why = [@"the judge found evidence: " stringByAppendingString:[why substringFromIndex:10]];
    return @[@"Staying on.", NSColor.systemGreenColor, [Sentence(Cut(why, 200)) stringByAppendingString:next]];
}

/// Git in a few words: when it last changed, whether everything is in the default branch, and what is left.
static NSString *GitState(NSDictionary *g) {
    if (!g) return nil;
    NSMutableArray *p = [NSMutableArray new];
    if (g[@"last_commit_minutes_ago"]) [p addObject:[NSString stringWithFormat:@"last commit %@ ago", [LHDuration([g[@"last_commit_minutes_ago"] doubleValue] * 60) componentsSeparatedByString:@" "].firstObject]];
    NSInteger out = [g[@"commits_not_in_default"] integerValue];
    if (g[@"commits_not_in_default"]) [p addObject:out ? [NSString stringWithFormat:@"%@ not in %@", Plural(out, @"commit"), g[@"default_branch"] ?: @"main"]
                                                       : [NSString stringWithFormat:@"all in %@", g[@"default_branch"] ?: @"main"]];
    if ([g[@"dirty_files"] integerValue]) [p addObject:Plural([g[@"dirty_files"] integerValue], @"uncommitted file")];
    if ([g[@"upstream"] isEqual:@"gone"]) [p addObject:@"remote branch deleted"];
    return [p componentsJoinedByString:@" · "];
}

/// The readable card at the top of a host's submenu.
- (NSMenuItem *)cardFor:(LHHost *)h {
    CGFloat inner = 350;
    LHVerdict *v = self.review.verdicts[h.key];
    NSDictionary *intel = LHIntel(h, NO);
    NSStackView *s = [NSStackView new];
    s.orientation = NSUserInterfaceLayoutOrientationVertical; s.alignment = NSLayoutAttributeLeading; s.spacing = 8;
    s.edgeInsets = NSEdgeInsetsMake(10, 16, 10, 16);

    NSString *title = v.about.length ? v.about : WhatWords(h, v, intel) ?: [NSString stringWithFormat:@"%@ in %@", h.framework, h.project];
    [s addArrangedSubview:Para(Sentence(title), [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], NSColor.labelColor, inner, 2)];
    NSArray *st = [self statusFor:h];
    NSTextField *status = Para(@"", [NSFont systemFontOfSize:12.5], NSColor.labelColor, inner, 4);
    status.attributedStringValue = Rich(st[0], st[1], st[2], 12.5);
    [status.constraints.lastObject setConstant:[status.cell cellSizeForBounds:NSMakeRect(0, 0, inner, 4000)].height];
    [s addArrangedSubview:status];

    // Facts as label and value, in two columns.
    NSMutableArray *rows = [NSMutableArray new];
    void (^fact)(NSString *, NSString *) = ^(NSString *label, NSString *value) {
        if (!value.length) return;
        NSTextField *l = [NSTextField labelWithString:label]; l.font = [NSFont systemFontOfSize:11.5]; l.textColor = NSColor.tertiaryLabelColor;
        NSTextField *x = [NSTextField labelWithString:value]; x.font = [NSFont systemFontOfSize:12]; x.textColor = NSColor.labelColor;
        x.lineBreakMode = NSLineBreakByTruncatingTail; [x.widthAnchor constraintLessThanOrEqualToConstant:inner - 70].active = YES;
        x.toolTip = value;
        [rows addObject:@[l, x]];
    };
    NSDictionary *where = LHWhere(h, NO);
    fact(@"Where", where[@"label"]);
    fact(@"Up", LHDuration(-h.started.timeIntervalSinceNow));
    fact(@"Started", h.launcher.length ? h.launcher : @"unknown");
    fact(@"Uses", [NSString stringWithFormat:@"%@ · %@ CPU now%@", LHFormatBytes(h.memory), Pct(h.cpuPercent),
                   h.clients.count ? [@" · " stringByAppendingString:[h.clients componentsJoinedByString:@", "]] : @""]);
    fact(@"Project", [NSString stringWithFormat:@"%@%@", h.project, h.branch ? [@" · " stringByAppendingString:h.branch] : @""]);
    if ([h.kind isEqualToString:@"dev"]) fact(@"Agent", intel ? SessionWords(intel[@"session"]) : @"looking…");
    fact(@"Git", GitState(intel[@"git"]));
    if (h.title.length) fact(@"Page", h.title);
    if (rows.count) {
        NSGridView *g = [NSGridView gridViewWithViews:rows];
        g.rowSpacing = 4; g.columnSpacing = 10; [g columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
        [s addArrangedSubview:g];
    }
    if (v.reason.length)
        [s addArrangedSubview:Para([NSString stringWithFormat:@"%@ says %@: %@", LHModelLabel(self.review.model), [v.verdict stringByReplacingOccurrencesOfString:@"_" withString:@" "], v.reason],
                                   [NSFont systemFontOfSize:11.5], NSColor.secondaryLabelColor, inner, 3)];
    NSSize fit = s.fittingSize;
    s.frame = NSMakeRect(0, 0, MAX(fit.width, inner + 32), fit.height);
    NSMenuItem *i = [NSMenuItem new]; i.view = s;
    return i;
}

- (NSMenuItem *)hostItem:(LHHost *)h {
    NSString *name = ShortName(h);
    if (self.prefix.length && [h.kind isEqualToString:@"dev"] && [name hasPrefix:self.prefix] && name.length > self.prefix.length) name = [name substringFromIndex:self.prefix.length];
    NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:h.framework action:nil keyEquivalent:@""];
    NSString *state = h.clients.count ? [@"in " stringByAppendingString:h.clients.firstObject] : StateWords(h);
    NSString *sub = [NSString stringWithFormat:@"%@ · %@ · up %@ · %@", h.framework, LHFormatBytes(h.memory),
                     [LHDuration(-h.started.timeIntervalSinceNow) componentsSeparatedByString:@" "].firstObject, Cut(state, 34)];
    if (ModernMenu()) {
        if (@available(macOS 14.4, *)) {
            i.title = [NSString stringWithFormat:@"%@   :%ld", Cut(name, 40), (long)h.port];
            i.subtitle = sub;
            if ([StateMark(h, self.review) isEqualToString:@"◇"]) i.badge = [[NSMenuItemBadge alloc] initWithString:@"idle"];
            else if ([self.plan[h.key][@"stop"] boolValue]) i.badge = [[NSMenuItemBadge alloc] initWithString:@"stops next"];
        }
    } else i.attributedTitle = [self rowTitle:h];

    NSMenu *m = [NSMenu new];
    [m addItem:[self cardFor:h]];
    [m addItem:NSMenuItem.separatorItem];
    NSDictionary *where = LHWhere(h, NO);
    if (where && ![where[@"label"] hasSuffix:@"has closed"]) {
        NSString *to = [where[@"tab"] length] ? [NSString stringWithFormat:@"Go to “%@”", Cut(where[@"tab"], 40)] : [@"Go to " stringByAppendingString:where[@"app"]];
        Item(m, to, @selector(goTo:), self, NO).representedObject = where;
    }
    if (![h.kind isEqualToString:@"service"] || h.httpStatus) Item(m, [@"Open " stringByAppendingString:h.url], @selector(openHost:), self, NO).representedObject = h;
    if (h.cwd.length > 1) Item(m, @"Reveal in Finder", @selector(reveal:), self, NO).representedObject = h;
    [m addItem:NSMenuItem.separatorItem];
    NSDate *kept = KeptUntil(h);
    Item(m, kept ? [NSString stringWithFormat:@"Kept for %@ More", LHDuration(kept.timeIntervalSinceNow)] : @"Keep for 4 Hours",
         @selector(toggleKeep:), self, kept != nil).representedObject = h;
    Item(m, @"Stop", @selector(stopOne:), self, NO).representedObject = h;
    NSMenu *more = [NSMenu new];
    if (![h.kind isEqualToString:@"service"] || h.httpStatus) Item(more, @"Copy URL", @selector(copyURL:), self, NO).representedObject = h;
    Item(more, @"Copy Restart Command", @selector(copyRestart:), self, NO).representedObject = h;
    Item(more, @"Protect", @selector(toggleProtect:), self, [LHRules.shared protectsPort:h.port]).representedObject = h;
    [more addItem:NSMenuItem.separatorItem];
    Item(more, @"Force Stop", @selector(killOne:), self, NO).representedObject = h;
    Sub(m, @"More", more);
    i.submenu = m;
    return i;
}

- (void)handleClick:(id)sender {
    [self.scanner sample];
    LHReview *r = self.review;
    NSArray<LHHost *> *hosts = self.scanner.hosts;
    NSArray<LHHost *> *idle = Candidates(hosts, r);
    NSPredicate *dev = [NSPredicate predicateWithFormat:@"kind == 'dev'"];
    NSArray *devs = [hosts filteredArrayUsingPredicate:dev];
    NSArray *inUse = [devs filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"state != %d", LHIdle]];
    NSArray *quiet = [devs filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"state == %d", LHIdle]];
    NSArray *services = [hosts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind == 'service'"]];
    NSArray *others = [hosts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind == 'other'"]];
    uint64_t idleMem = 0; double cpu = 0;
    for (LHHost *h in hosts) cpu += h.cpuPercent;
    for (LHHost *h in idle) idleMem += h.memory;

    NSMutableDictionary *plan = [NSMutableDictionary new];
    for (NSDictionary *p in Plan(hosts, r, Mode(), NO)) plan[[p[@"host"] key]] = p;
    self.plan = plan;

    // The start every dev server's name shares, up to a dash, such as "barkpark-", is left out of the rows.
    NSString *common = nil;
    for (LHHost *h in devs) common = common ? [common commonPrefixWithString:ShortName(h) options:0] : ShortName(h);
    NSRange dash = [common rangeOfString:@"-" options:NSBackwardsSearch];
    self.prefix = devs.count > 1 && dash.location != NSNotFound && dash.location >= 3 ? [common substringToIndex:dash.location + 1] : nil;

    NSMenu *menu = [NSMenu new];
    uint64_t quietMem = 0; for (LHHost *h in quiet) quietMem += h.memory;
    NSString *line = [NSString stringWithFormat:@"%@ · %lu in use%@ · %@", Plural(devs.count + services.count, @"localhost"),
                      (unsigned long)(inUse.count + services.count), quiet.count ? [NSString stringWithFormat:@" · %lu quiet, %@", (unsigned long)quiet.count, LHFormatBytes(quietMem)] : @"", ModeLabel(Mode())];
    NSMenuItem *head = [NSMenuItem new];
    head.view = MenuHeader([hosts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind != 'other'"]], r, line, cpu);
    [menu addItem:head];

    [menu addItem:NSMenuItem.separatorItem];

    // What is going on, in up to four readable lines. The review's details sit under Review Now.
    if (r.summary.length) [menu addItem:TextItem(r.summary, 4)];
    else if (r.error) [menu addItem:TextItem([@"The last review failed: " stringByAppendingString:r.error], 3)];
    [menu addItem:NSMenuItem.separatorItem];
    if (idle.count) {
        NSMenuItem *go = Item(menu, @"Close Idle", @selector(closeIdle), self, NO);
        go.attributedTitle = Titled(@"Close Idle", [NSString stringWithFormat:@"%@ · %@", Plural(idle.count, @"server"), LHFormatBytes(idleMem)]);
        go.toolTip = [NSString stringWithFormat:@"Quiet for %ld minutes, called idle by the last review, and nothing since. Services and protected ports are never included.", (long)IdleMinutes()];
    }
    NSMenuItem *rv = Item(menu, self.reviewing ? @"Reviewing…" : @"Review Now", @selector(reviewNow), self, NO);
    rv.attributedTitle = Titled(rv.title, self.reviewing ? LHModelLabel(Model()) : r ? [NSString stringWithFormat:@"%@ ago", LHDuration(-r.at.timeIntervalSinceNow)] : @"");
    rv.toolTip = r ? [NSString stringWithFormat:@"Last review by %@, %@, %.0f s%@%@", LHModelLabel(r.model), Tokens(r.tokens), r.seconds,
                      r.trigger && ![r.trigger isEqualToString:@"manual"] ? [@", woken by " stringByAppendingString:r.trigger] : @"", r.note ? [@". " stringByAppendingString:r.note] : @""] : nil;
    rv.enabled = !self.reviewing && hosts.count;

    if (!hosts.count) Header(menu, @"No localhosts running");
    if (inUse.count) { Section(menu, @"In use"); for (LHHost *h in inUse) [menu addItem:[self hostItem:h]]; }
    if (quiet.count) { Section(menu, @"Quiet"); for (LHHost *h in quiet) [menu addItem:[self hostItem:h]]; }
    if (services.count) { Section(menu, @"Services"); for (LHHost *h in services) [menu addItem:[self hostItem:h]]; }
    [menu addItem:NSMenuItem.separatorItem];
    NSArray *closed = Closed();
    if (closed.count) {
        NSMenu *cm = [NSMenu new];
        for (NSDictionary *c in closed) {
            NSMenu *sm = [NSMenu new];
            if ([c[@"why"] length]) for (NSString *line in Wrap(c[@"why"], 64)) Header(sm, line);
            Header(sm, Cut(c[@"restart"], 70)).toolTip = c[@"restart"];
            [sm addItem:NSMenuItem.separatorItem];
            NSMenuItem *ri = Item(sm, @"Restart", @selector(restartClosed:), self, NO);
            ri.representedObject = c; ri.enabled = !LHPortListening([c[@"port"] integerValue]);
            Item(sm, @"Copy Restart Command", @selector(copyClosed:), self, NO).representedObject = c[@"restart"];
            NSMenuItem *ci = Sub(cm, @"", sm);
            ci.attributedTitle = Titled([NSString stringWithFormat:@":%@  %@", c[@"port"], c[@"framework"]],
                                        [NSString stringWithFormat:@"%@ ago by %@", LHDuration(NSDate.date.timeIntervalSince1970 - [c[@"at"] doubleValue]), c[@"by"] ?: @"you"]);
        }
        [cm addItem:NSMenuItem.separatorItem];
        Item(cm, @"Clear", @selector(clearClosed), self, NO);
        Sub(menu, @"Recently Stopped", cm);
    }
    if (others.count) {
        NSMenu *om = [NSMenu new];
        for (LHHost *h in others) [om addItem:[self hostItem:h]];
        Sub(menu, @"Other Listeners", om);
    }

    NSMenu *set = [NSMenu new];
    NSMenu *modes = [NSMenu new];
    NSArray *modeHelp = @[@"Reviews and reports. Stops nothing by itself.",
                          @"Stops obvious waste: quiet 6 hours, no agent, the review sure.",
                          @"Stops every quiet server that can't show evidence it's needed."];
    for (LHMode m = LHModeIdle; m <= LHModeEager; m++) {
        NSMenuItem *mi = Item(modes, @"", @selector(setMode:), self, Mode() == m);
        mi.attributedTitle = Titled(ModeLabel(m), modeHelp[m]); mi.tag = m;
    }
    [modes addItem:NSMenuItem.separatorItem];
    Header(modes, @"No mode stops a server used in the quiet window, younger than");
    Header(modes, @"30 minutes, protected, kept, or with an agent active in the last hour.");
    Sub(set, [NSString stringWithFormat:@"Mode: %@", ModeLabel(Mode())], modes);
    NSMenu *models = [NSMenu new];
    BOOL known = NO;
    for (NSArray *m in LHModels()) { BOOL on = [Model() isEqualToString:m[0]]; known |= on; Item(models, m[1], @selector(setModel:), self, on).representedObject = m[0]; }
    if (!known) Item(models, Model(), NULL, nil, YES).enabled = NO;
    [models addItem:NSMenuItem.separatorItem];
    Header(models, @"Haiku first, Luna when Claude is out of usage.");
    Header(models, @"Both on your own login, with no tools.");
    Sub(set, [NSString stringWithFormat:@"Model: %@", LHModelLabel(Model())], models);
    NSMenu *every = [NSMenu new];
    for (NSNumber *m in @[@0, @15, @30, @60, @120, @240])
        Item(every, m.integerValue ? LHDuration(m.integerValue * 60) : @"Off", @selector(setReviewEvery:), self, PrefInt(kReviewMinKey, 60) == m.integerValue).tag = m.integerValue;
    [every addItem:NSMenuItem.separatorItem];
    Header(every, @"New servers, long uptimes and memory pressure also wake a review.");
    Sub(set, [NSString stringWithFormat:@"Review Every: %@", PrefInt(kReviewMinKey, 60) ? LHDuration(PrefInt(kReviewMinKey, 60) * 60) : @"Off"], every);
    NSMenu *quietAfter = [NSMenu new];
    for (NSNumber *m in @[@10, @30, @60, @120, @360])
        Item(quietAfter, LHDuration(m.integerValue * 60), @selector(setIdle:), self, IdleMinutes() == m.integerValue).tag = m.integerValue;
    Sub(set, [NSString stringWithFormat:@"Quiet After: %@", LHDuration(IdleMinutes() * 60)], quietAfter);
    NSMenu *f = [NSMenu new];
    Item(f, @"Ask Me", @selector(setForce:), self, ForceMode() == LHForceAsk).tag = LHForceAsk;
    Item(f, @"Force Stop It", @selector(setForce:), self, ForceMode() == LHForceAlways).tag = LHForceAlways;
    Item(f, @"Leave It Running", @selector(setForce:), self, ForceMode() == LHForceNever).tag = LHForceNever;
    [f addItem:NSMenuItem.separatorItem];
    Header(f, [NSString stringWithFormat:@"Servers get SIGTERM and %.0f seconds first.", kGrace]);
    Sub(set, @"When a Server Won't Stop", f);
    [set addItem:NSMenuItem.separatorItem];
    Item(set, @"Ask Before Closing", @selector(toggleAsk), self, PrefBool(kAskKey, YES));
    Item(set, @"Read Page Titles", @selector(toggleProbe), self, PrefBool(kProbeKey, YES)).toolTip = @"Sends GET / to each dev server every 5 minutes to read its page title.";
    Item(set, @"Launch at Login", @selector(toggleLogin), self, SMAppService.mainAppService.status == SMAppServiceStatusEnabled);
    Item(set, @"Edit Rules…", @selector(editRules), self, NO);
    if (self.scanner.ignored.count) {
        NSMenu *im = [NSMenu new];
        for (LHIgnored *i in self.scanner.ignored)
            Header(im, [NSString stringWithFormat:@"%@   :%@", i.name, [[i.ports valueForKey:@"stringValue"] componentsJoinedByString:@", :"]]);
        [im addItem:NSMenuItem.separatorItem];
        Header(im, @"macOS services and apps. LocoHost never touches them.");
        Sub(set, [NSString stringWithFormat:@"Ignored Listeners (%lu)", (unsigned long)self.scanner.ignored.count], im);
    }
    [set addItem:NSMenuItem.separatorItem];
    Header(set, [NSString stringWithFormat:@"LocoHost %@ · watching for %@", NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"",
                 LHDuration(-self.scanner.watchingSince.timeIntervalSinceNow)]);
    Sub(menu, @"Settings", set);
    Item(menu, @"Quit LocoHost", @selector(quit), self, NO).keyEquivalent = @"q";

    self.statusItem.menu = menu;
    [self.statusItem.button performClick:nil];
    self.statusItem.menu = nil;
}

#pragma mark Actions

- (void)closeIdle { [self closeIdleConfirm:PrefBool(kAskKey, YES)]; }

- (void)closeIdleConfirm:(BOOL)confirm {
    [self.scanner sample];   // re-check right before acting
    NSArray<LHHost *> *c = Candidates(self.scanner.hosts, self.review);
    if (!c.count) return;
    if (confirm) {
        NSAlert *a = [NSAlert new];
        uint64_t mem = 0; for (LHHost *h in c) mem += h.memory;
        a.messageText = [NSString stringWithFormat:@"Stop %@ (%@)?", Plural(c.count, @"idle server"), LHFormatBytes(mem)];
        NSMutableString *list = [NSMutableString new];
        for (LHHost *h in c)
            [list appendFormat:@"•  :%ld %@, %@, up %@\n     %@\n", (long)h.port, h.framework, h.project, LHDuration(-h.started.timeIntervalSinceNow),
                               self.review.verdicts[h.key].reason ?: @""];
        [list appendFormat:@"\nEach gets SIGTERM and %.0f seconds. Recently Stopped keeps each restart command.", kGrace];
        a.informativeText = list;
        [a addButtonWithTitle:@"Stop Them"]; [a addButtonWithTitle:@"Cancel"];
        a.showsSuppressionButton = YES; a.suppressionButton.title = @"Don't ask again";
        [NSApp activateIgnoringOtherApps:YES];
        if ([a runModal] != NSAlertFirstButtonReturn) return;
        if (a.suppressionButton.state == NSControlStateValueOn) PrefSet(kAskKey, @NO);
    }
    [self escalate:StopHosts(c, kGrace)];
    [self tick];
}

/// What to do with servers that ignored SIGTERM, per the user's setting.
- (void)escalate:(NSArray<LHHost *> *)left {
    if (!left.count) return;
    LHForceMode mode = ForceMode();
    if (mode == LHForceAsk) {
        NSAlert *a = [NSAlert new];
        a.alertStyle = NSAlertStyleWarning;
        a.messageText = [NSString stringWithFormat:@"%@ did not stop", Plural(left.count, @"server")];
        NSMutableString *names = [NSMutableString new];
        for (LHHost *h in left) [names appendFormat:@":%ld %@ (pid %d)\n", (long)h.port, h.framework, h.pid];
        a.informativeText = [names stringByAppendingString:@"\nForce stopping sends SIGKILL. Whatever the server held in memory is lost."];
        [a addButtonWithTitle:@"Force Stop"]; [a addButtonWithTitle:@"Leave Running"];
        a.buttons.firstObject.hasDestructiveAction = YES;
        [NSApp activateIgnoringOtherApps:YES];
        if ([a runModal] != NSAlertFirstButtonReturn) return;
        mode = LHForceAlways;
    }
    if (mode == LHForceAlways) KillHosts(left);
}

- (void)stopOne:(NSMenuItem *)i {
    LHHost *h = i.representedObject;
    if (PrefBool(kAskKey, YES)) {
        NSAlert *a = [NSAlert new];
        a.messageText = [NSString stringWithFormat:@"Stop :%ld %@?", (long)h.port, h.framework];
        a.informativeText = [NSString stringWithFormat:@"%@\n%@\n\nRestart with:\n%@", h.project, h.launcher, h.restartCommand];
        [a addButtonWithTitle:@"Stop"]; [a addButtonWithTitle:@"Cancel"];
        [NSApp activateIgnoringOtherApps:YES];
        if ([a runModal] != NSAlertFirstButtonReturn) return;
    }
    [self escalate:StopHosts(@[h], kGrace)];
    [self tick];
}

- (void)killOne:(NSMenuItem *)i {
    LHHost *h = i.representedObject;
    NSAlert *a = [NSAlert new];
    a.alertStyle = NSAlertStyleWarning;
    a.messageText = [NSString stringWithFormat:@"Force stop :%ld %@?", (long)h.port, h.framework];
    a.informativeText = @"It gets SIGKILL immediately. Whatever it held in memory is lost.";
    [a addButtonWithTitle:@"Force Stop"]; [a addButtonWithTitle:@"Cancel"];
    a.buttons.firstObject.hasDestructiveAction = YES;
    [NSApp activateIgnoringOtherApps:YES];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    RememberClosed(@[h], nil, nil); KillHosts(@[h]); [self tick];
}

static void Copy(NSString *s) { [NSPasteboard.generalPasteboard clearContents]; [NSPasteboard.generalPasteboard setString:s forType:NSPasteboardTypeString]; }
- (void)openHost:(NSMenuItem *)i    { LHHost *h = i.representedObject; [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:h.url]]; }
- (void)copyURL:(NSMenuItem *)i     { LHHost *h = i.representedObject; Copy(h.url); }
- (void)copyRestart:(NSMenuItem *)i { LHHost *h = i.representedObject; Copy(h.restartCommand); }
- (void)copyClosed:(NSMenuItem *)i  { Copy(i.representedObject); }
- (void)clearClosed                 { SetClosed(@[]); }
- (void)goTo:(NSMenuItem *)i {
    NSString *e = nil;
    if (LHGoTo(i.representedObject, &e) || !e) return;
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:@"Could not go to %@", i.representedObject[@"app"]];
    a.informativeText = e;
    [NSApp activateIgnoringOtherApps:YES]; [a runModal];
}
- (void)toggleKeep:(NSMenuItem *)i  { LHHost *h = i.representedObject; SetKeep(h, KeptUntil(h) ? 0 : 4); }
- (void)restartClosed:(NSMenuItem *)i {
    NSDictionary *c = i.representedObject; NSString *e = nil;
    if (!Restart(c[@"restart"], &e)) {
        NSAlert *a = [NSAlert new];
        a.messageText = [NSString stringWithFormat:@"Could not restart :%@", c[@"port"]];
        a.informativeText = e ?: @"";
        [NSApp activateIgnoringOtherApps:YES]; [a runModal];
    }
}
- (void)reveal:(NSMenuItem *)i      { LHHost *h = i.representedObject; [NSWorkspace.sharedWorkspace selectFile:nil inFileViewerRootedAtPath:h.cwd]; }
- (void)toggleProtect:(NSMenuItem *)i {
    LHHost *h = i.representedObject;
    [LHRules.shared setProtected:![LHRules.shared protectsPort:h.port] port:h.port]; [self tick];
}
- (void)setReviewEvery:(NSMenuItem *)i { PrefSet(kReviewMinKey, @(i.tag)); }
- (void)setModel:(NSMenuItem *)i       { PrefSet(kModelKey, i.representedObject); }
- (void)setMode:(NSMenuItem *)i        { PrefSet(kModeKey, ModeNames()[i.tag]); }
- (void)setIdle:(NSMenuItem *)i        { PrefSet(kIdleMinKey, @(i.tag)); [self tick]; }
- (void)setForce:(NSMenuItem *)i       { PrefSet(kForceKey, @(i.tag)); }
- (void)toggleAsk                      { PrefSet(kAskKey, @(!PrefBool(kAskKey, YES))); }
- (void)toggleProbe                    { PrefSet(kProbeKey, @(!PrefBool(kProbeKey, YES))); }
- (void)editRules { [LHRules.shared reload]; [NSWorkspace.sharedWorkspace openURL:LHRules.shared.fileURL]; }
- (void)toggleLogin {
    SMAppService *s = SMAppService.mainAppService; NSError *e = nil;
    if (s.status == SMAppServiceStatusEnabled) [s unregisterAndReturnError:&e]; else [s registerAndReturnError:&e];
    if (e) NSBeep();
}
- (void)quit { [NSApp terminate:nil]; }

/// locohost://review | close-idle (with confirmation) | login-on | login-off | quit
- (void)application:(NSApplication *)app openURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *u in urls) {
        NSString *c = u.host.lowercaseString ?: @"";
        if      ([c isEqualToString:@"review"])     [self reviewNow];
        else if ([c isEqualToString:@"close-idle"]) [self closeIdleConfirm:YES];
        else if ([c isEqualToString:@"login-on"] || [c isEqualToString:@"login-off"]) {
            BOOL want = [c isEqualToString:@"login-on"];
            if ((SMAppService.mainAppService.status == SMAppServiceStatusEnabled) != want) [self toggleLogin];
        }
        else if ([c isEqualToString:@"quit"])       [NSApp terminate:nil];
    }
}

@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc > 1 && argv[1][0] != '-') return RunCLI(argc, argv);    // CLI mode
        if (argc > 1 && (!strcmp(argv[1], "--help") || !strcmp(argv[1], "-h"))) return Usage();
        NSApplication *app = NSApplication.sharedApplication;
        LocoHost *delegate = [LocoHost new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
