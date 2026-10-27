#import "Where.h"
#import <AppKit/AppKit.h>
#import <libproc.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <sys/sysctl.h>

static const NSTimeInterval kSnapshotAge = 15;   // cmux and tmux are asked at most this often

#pragma mark - Processes

/// Runs a CLI for at most three seconds. Returns its output, or nil when it failed or took too long.
static NSString *Run(NSString *path, NSArray<NSString *> *args) {
    if (!path) return nil;
    NSTask *t = [NSTask new]; NSPipe *out = [NSPipe pipe];
    t.executableURL = [NSURL fileURLWithPath:path]; t.arguments = args;
    t.standardOutput = out; t.standardError = NSFileHandle.fileHandleWithNullDevice; t.standardInput = NSFileHandle.fileHandleWithNullDevice;
    if (![t launchAndReturnError:nil]) return nil;
    __block NSData *d = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ d = [out.fileHandleForReading readDataToEndOfFile]; dispatch_semaphore_signal(done); });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC))) { [t terminate]; return nil; }
    [t waitUntilExit];
    return t.terminationStatus == 0 ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
}

/// The process table entry. Unlike proc_pidinfo it also reads processes owned by root, such as Terminal's login.
static BOOL KInfo(pid_t p, struct kinfo_proc *k) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, p};
    size_t len = sizeof *k;
    return sysctl(mib, 4, k, &len, NULL, 0) == 0 && len == sizeof *k;
}
static pid_t ParentOf(pid_t p) { struct kinfo_proc k; return KInfo(p, &k) ? k.kp_eproc.e_ppid : 0; }
static NSString *TTYOf(pid_t p) {
    struct kinfo_proc k;
    if (!KInfo(p, &k) || k.kp_eproc.e_tdev == NODEV || k.kp_eproc.e_tdev == 0) return nil;
    char *n = devname(k.kp_eproc.e_tdev, S_IFCHR);
    return n && strcmp(n, "??") ? @(n) : nil;
}
static NSString *ExecPath(pid_t p) {
    char buf[PROC_PIDPATHINFO_MAXSIZE];
    return proc_pidpath(p, buf, sizeof buf) > 0 ? @(buf) : nil;
}
/// The app macOS holds responsible for a process. It is set when the process starts and survives its parent exiting.
static pid_t Responsible(pid_t p) {
    static pid_t (*f)(pid_t); static dispatch_once_t once;
    dispatch_once(&once, ^{ f = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid"); });
    return f ? f(p) : 0;
}

/// The server, the package manager wrapper above it, and every parent of both up to launchd.
static NSArray<NSNumber *> *Chain(LHHost *h) {
    NSMutableOrderedSet *c = [NSMutableOrderedSet new];
    for (NSNumber *start in @[@(h.pid), @(h.wrapperPid)]) {
        pid_t p = start.intValue;
        for (int i = 0; p > 1 && i < 64; i++, p = ParentOf(p)) [c addObject:@(p)];
    }
    return c.array;
}

/// The running app a process belongs to: the first parent that is a regular app, else the responsible app.
static NSRunningApplication *AppOf(NSArray<NSNumber *> *chain, pid_t server) {
    NSMutableArray *pids = [chain mutableCopy];
    pid_t r = Responsible(server);
    if (r > 1) [pids addObject:@(r)];
    for (NSNumber *p in pids) {
        NSRunningApplication *a = [NSRunningApplication runningApplicationWithProcessIdentifier:p.intValue];
        if (a.bundleIdentifier && a.activationPolicy == NSApplicationActivationPolicyRegular && a.processIdentifier != getpid()) return a;
        NSString *exec = ExecPath(p.intValue);
        NSRange app = [exec rangeOfString:@".app/Contents/"];
        if (app.location == NSNotFound) continue;
        NSString *bundle = [exec substringToIndex:app.location + 4];
        for (NSRunningApplication *ra in NSWorkspace.sharedWorkspace.runningApplications)
            if ([ra.bundleURL.path isEqualToString:bundle] && ra.activationPolicy == NSApplicationActivationPolicyRegular) return ra;
    }
    return nil;
}

/// "◐ Frikkern repo check" reads "Frikkern repo check": cmux puts a status glyph in front of agent tabs.
static NSString *Clean(NSString *title) {
    NSCharacterSet *keep = NSCharacterSet.alphanumericCharacterSet;
    NSUInteger i = 0;
    while (i < title.length && ![keep characterIsMember:[title characterAtIndex:i]] && [title characterAtIndex:i] != '~' && [title characterAtIndex:i] != '/') i++;
    return [[title substringFromIndex:i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}
static NSString *LastWord(NSString *s) { return [s componentsSeparatedByString:@" "].lastObject; }

#pragma mark - cmux

static NSString *CmuxPath(void) {
    NSURL *u = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.cmuxterm.app"];
    NSString *p = [u.path stringByAppendingPathComponent:@"Contents/Resources/bin/cmux"];
    return [NSFileManager.defaultManager isExecutableFileAtPath:p] ? p : nil;
}

/// cmux's own process list: every process under its window, workspace, pane and tab. One call covers every host.
static NSDictionary *CmuxSnapshot(void) {
    static NSDictionary *snap; static NSDate *at;
    @synchronized (NSRunningApplication.class) {
        if (snap && -at.timeIntervalSinceNow < kSnapshotAge) return snap;
        NSMutableDictionary *procs = [NSMutableDictionary new], *objs = [NSMutableDictionary new];
        BOOL running = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.cmuxterm.app"].count > 0;
        NSString *out = running ? Run(CmuxPath(), @[@"top", @"--all", @"--processes", @"--format", @"tsv", @"--id-format", @"both"]) : nil;
        for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
            NSArray *c = [line componentsSeparatedByString:@"\t"];
            if (c.count < 6) continue;
            NSString *type = c[3], *idf = c[4], *parent = c[5], *title = c.count > 6 ? c[6] : @"";
            if ([type isEqualToString:@"process"]) procs[@([idf intValue])] = parent;
            else if (![type isEqualToString:@"webview"]) objs[idf] = @[type, parent, title];
        }
        snap = @{@"procs": procs, @"objs": objs}; at = NSDate.date;
        return snap;
    }
}

static NSDictionary *InCmux(NSArray<NSNumber *> *chain) {
    NSDictionary *snap = CmuxSnapshot(), *procs = snap[@"procs"], *objs = snap[@"objs"];
    if (![procs count]) return nil;
    for (NSNumber *pid in chain) {
        NSString *parent = procs[pid];
        for (int i = 0; parent.length && [parent rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location == NSNotFound && i < 64; i++)
            parent = procs[@(parent.intValue)];   // a parent that is itself a process
        if (!parent) continue;
        NSMutableDictionary *found = [NSMutableDictionary new];
        for (NSString *key = parent; objs[key]; key = objs[key][1]) found[objs[key][0]] = @[key, objs[key][2]];
        NSArray *surface = found[@"surface"], *workspace = found[@"workspace"], *window = found[@"window"];
        if (!surface || !workspace) continue;
        // The workspace title follows whichever tab is selected, so only the tab is named.
        NSString *tab = Clean(surface[1]);
        NSMutableArray *parts = [NSMutableArray arrayWithObject:@"cmux"];
        if (tab.length) [parts addObject:tab];
        NSRunningApplication *app = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.cmuxterm.app"].firstObject;
        return @{@"kind": @"cmux", @"app": @"cmux", @"label": [parts componentsJoinedByString:@" › "], @"tab": tab ?: @"",
                 @"workspace": LastWord(workspace[0]), @"surface": LastWord(surface[0]), @"window": window ? LastWord(window[0]) : @"",
                 @"pid": @(app.processIdentifier)};
    }
    return nil;
}

#pragma mark - tmux

static NSString *TmuxPath(void) {
    for (NSString *p in @[@"/opt/homebrew/bin/tmux", @"/usr/local/bin/tmux", @"/usr/bin/tmux"])
        if ([NSFileManager.defaultManager isExecutableFileAtPath:p]) return p;
    return nil;
}

/// Every tmux pane's shell, by pid, and which process runs each session's client.
static NSDictionary *TmuxSnapshot(void) {
    static NSDictionary *snap; static NSDate *at;
    @synchronized (NSFileManager.class) {
        if (snap && -at.timeIntervalSinceNow < kSnapshotAge) return snap;
        NSMutableDictionary *panes = [NSMutableDictionary new], *clients = [NSMutableDictionary new];
        NSString *tmux = TmuxPath();
        NSString *out = Run(tmux, @[@"list-panes", @"-a", @"-F", @"#{pane_pid}\t#{pane_id}\t#{session_name}\t#{window_index}\t#{window_name}\t#{pane_index}"]);
        for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
            NSArray *c = [line componentsSeparatedByString:@"\t"];
            if (c.count == 6) panes[@([c[0] intValue])] = c;
        }
        if (panes.count)
            for (NSString *line in [Run(tmux, @[@"list-clients", @"-F", @"#{client_pid}\t#{client_session}"]) componentsSeparatedByString:@"\n"]) {
                NSArray *c = [line componentsSeparatedByString:@"\t"];
                if (c.count == 2) clients[c[1]] = @([c[0] intValue]);
            }
        snap = @{@"panes": panes, @"clients": clients}; at = NSDate.date;
        return snap;
    }
}

static NSDictionary *InCmux(NSArray<NSNumber *> *chain);

/// A tmux pane whose shell is above the server. When the session's client runs in a cmux tab, that tab is kept too,
/// so going there opens the tab first and then the pane.
static NSDictionary *InTmux(NSArray<NSNumber *> *chain, pid_t server) {
    NSDictionary *snap = TmuxSnapshot(), *panes = snap[@"panes"];
    for (NSNumber *pid in chain) {
        NSArray *p = panes[pid];
        if (!p) continue;
        pid_t client = [snap[@"clients"][p[2]] intValue];
        NSMutableArray *clientChain = [NSMutableArray new];
        for (pid_t c = client; c > 1 && clientChain.count < 64; c = ParentOf(c)) [clientChain addObject:@(c)];
        NSDictionary *outer = clientChain.count ? InCmux(clientChain) : nil;
        NSRunningApplication *app = clientChain.count ? AppOf(clientChain, client) : nil;
        NSString *in = outer ? [NSString stringWithFormat:@" (in %@)", outer[@"label"]] : app ? [NSString stringWithFormat:@" (in %@)", app.localizedName] : @" (no client attached)";
        NSMutableDictionary *r = [@{@"kind": @"tmux", @"app": app.localizedName ?: @"tmux", @"label": [NSString stringWithFormat:@"tmux › %@ › %@%@", p[2], p[4], in],
                                    @"tab": p[4], @"target": p[1], @"pid": @(app.processIdentifier)} mutableCopy];
        if (outer) r[@"outer"] = outer;
        return r;
    }
    return nil;
}

#pragma mark - Lookup

static NSDictionary *Compute(LHHost *h) {
    NSArray *chain = Chain(h);
    NSDictionary *w = InTmux(chain, h.pid) ?: InCmux(chain);   // a tmux pane is more exact than the cmux tab that started tmux
    if (w) return w;
    NSRunningApplication *app = AppOf(chain, h.pid);
    if (!app) return nil;
    NSString *tty = nil;
    for (NSNumber *p in chain) if ((tty = TTYOf(p.intValue))) break;
    NSString *bundle = app.bundleIdentifier;
    NSString *kind = [bundle isEqualToString:@"com.apple.Terminal"] ? @"terminal" : [bundle isEqualToString:@"com.googlecode.iterm2"] ? @"iterm" : @"app";
    BOOL orphan = h.orphaned || [chain indexOfObject:@(app.processIdentifier)] == NSNotFound;
    NSString *label = app.localizedName;
    if (![kind isEqualToString:@"app"] && tty && !orphan) label = [NSString stringWithFormat:@"%@ › tab on %@", app.localizedName, tty];
    else if (orphan) label = [NSString stringWithFormat:@"%@ › the tab that started it has closed", app.localizedName];
    NSMutableDictionary *r = [@{@"kind": orphan ? @"app" : kind, @"app": app.localizedName ?: @"", @"label": label, @"pid": @(app.processIdentifier)} mutableCopy];
    if (tty && !orphan) r[@"tty"] = tty;
    return r;
}

static NSMutableDictionary *gWhere;
static dispatch_queue_t Queue(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("locohost.where", DISPATCH_QUEUE_SERIAL); gWhere = [NSMutableDictionary new]; });
    return q;
}

NSDictionary *LHWhere(LHHost *h, BOOL wait) {
    dispatch_queue_t q = Queue();
    if (wait) {
        NSDictionary *w = Compute(h);
        dispatch_sync(q, ^{ if (w) gWhere[h.key] = w; else [gWhere removeObjectForKey:h.key]; });
        return w;
    }
    __block NSDictionary *w = nil;
    dispatch_sync(q, ^{ w = gWhere[h.key]; });
    return w;
}

void LHWhereRefresh(NSArray<LHHost *> *hosts) {
    dispatch_queue_t q = Queue();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableDictionary *fresh = [NSMutableDictionary new];
        for (LHHost *h in hosts) { NSDictionary *w = Compute(h); if (w) fresh[h.key] = w; }
        dispatch_async(q, ^{ [gWhere setDictionary:fresh]; });
    });
}

#pragma mark - Going there

static NSString *TabScript(NSString *kind, NSString *tty) {
    NSString *dev = [@"/dev/" stringByAppendingString:tty];
    if ([kind isEqualToString:@"terminal"])
        return [NSString stringWithFormat:@"tell application id \"com.apple.Terminal\"\n"
                "repeat with w in windows\nrepeat with t in tabs of w\n"
                "if tty of t is \"%@\" then\nset selected of t to true\nset index of w to 1\nactivate\nreturn \"ok\"\nend if\n"
                "end repeat\nend repeat\nactivate\nreturn \"missing\"\nend tell", dev];
    return [NSString stringWithFormat:@"tell application id \"com.googlecode.iterm2\"\n"
            "repeat with w in windows\nrepeat with t in tabs of w\nrepeat with s in sessions of t\n"
            "if tty of s is \"%@\" then\nselect w\ntell t to select\ntell s to select\nactivate\nreturn \"ok\"\nend if\n"
            "end repeat\nend repeat\nend repeat\nactivate\nreturn \"missing\"\nend tell", dev];
}

static BOOL Activate(NSDictionary *w, NSString **error) {
    NSRunningApplication *a = [NSRunningApplication runningApplicationWithProcessIdentifier:[w[@"pid"] intValue]];
    if (!a) { if (error) *error = [NSString stringWithFormat:@"%@ is no longer running", w[@"app"] ?: @"the app"]; return NO; }
    [a activateWithOptions:NSApplicationActivateAllWindows];
    return YES;
}

BOOL LHGoTo(NSDictionary *w, NSString **error) {
    NSString *kind = w[@"kind"];
    if ([kind isEqualToString:@"cmux"]) {
        NSString *cmux = CmuxPath();
        NSMutableArray *win = [w[@"window"] length] ? [@[@"--window", w[@"window"]] mutableCopy] : [NSMutableArray new];
        if (win.count) Run(cmux, [@[@"focus-window"] arrayByAddingObjectsFromArray:win]);
        Run(cmux, [@[@"select-workspace", @"--workspace", w[@"workspace"]] arrayByAddingObjectsFromArray:win]);
        BOOL ok = Run(cmux, [@[@"focus-panel", @"--panel", w[@"surface"], @"--workspace", w[@"workspace"]] arrayByAddingObjectsFromArray:win]) != nil;
        Activate(w, nil);
        if (!ok && error) *error = @"cmux did not find the tab; it may have closed";
        return ok;
    }
    if ([kind isEqualToString:@"tmux"]) {
        if (w[@"outer"]) LHGoTo(w[@"outer"], nil);
        NSString *tmux = TmuxPath();
        Run(tmux, @[@"switch-client", @"-t", w[@"target"]]);
        Run(tmux, @[@"select-window", @"-t", w[@"target"]]);
        BOOL ok = Run(tmux, @[@"select-pane", @"-t", w[@"target"]]) != nil;
        if ([w[@"pid"] intValue] > 0) Activate(w, nil);
        if (!ok && error) *error = @"tmux did not find the pane; it may have closed";
        return ok;
    }
    if (([kind isEqualToString:@"terminal"] || [kind isEqualToString:@"iterm"]) && w[@"tty"]) {
        NSDictionary *err = nil;
        NSAppleEventDescriptor *r = [[[NSAppleScript alloc] initWithSource:TabScript(kind, w[@"tty"])] executeAndReturnError:&err];
        if (r && [r.stringValue isEqualToString:@"ok"]) return YES;
        Activate(w, nil);
        if (error) *error = err ? [NSString stringWithFormat:@"%@ did not allow LocoHost to select the tab: %@", w[@"app"], err[NSAppleScriptErrorMessage] ?: @"no permission"]
                                : @"the tab has closed";
        return NO;
    }
    return Activate(w, error);
}
