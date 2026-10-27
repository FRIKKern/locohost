#import "Ports.h"
#import "Rules.h"
#import <libproc.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <sys/sysctl.h>
#import <sys/proc_info.h>
#import <netinet/in.h>
#import <netinet/tcp_fsm.h>
#import <arpa/inet.h>

static const double kBusyCPU = 10.0;             // tree CPU% that counts as work, and at least 3x its lifetime average
static const NSTimeInterval kProbeQuiet = 15;    // CPU right after our own probe is ours, not activity
static const NSTimeInterval kProbeEvery = 300;

#pragma mark - Helpers

NSString *LHFormatBytes(uint64_t b) {
    if (b >= 1ull << 30) return [NSString stringWithFormat:@"%.1f GB", b / (double)(1ull << 30)];
    if (b >= 1ull << 20) return [NSString stringWithFormat:@"%.0f MB", b / (double)(1ull << 20)];
    return [NSString stringWithFormat:@"%.0f KB", b / 1024.0];
}

NSString *LHDuration(NSTimeInterval s) {
    long t = (long)MAX(0, s);
    if (t < 60) return [NSString stringWithFormat:@"%lds", t];
    if (t < 3600) return [NSString stringWithFormat:@"%ldm", t / 60];
    if (t < 86400) return t % 3600 >= 60 ? [NSString stringWithFormat:@"%ldh %ldm", t / 3600, t % 3600 / 60] : [NSString stringWithFormat:@"%ldh", t / 3600];
    return t % 86400 >= 3600 ? [NSString stringWithFormat:@"%ldd %ldh", t / 86400, t % 86400 / 3600] : [NSString stringWithFormat:@"%ldd", t / 86400];
}

NSString *LHSupportDir(void) {
    NSString *env = NSProcessInfo.processInfo.environment[@"LOCOHOST_HOME"];
    if (env.length) return env;
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/LocoHost"];
}

NSString *LHShellQuote(NSString *s) {
    if (s.length && [s rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@%+,"] invertedSet]].location == NSNotFound) return s;
    return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static BOOL Connects(const char *addr, int family, NSInteger port) {
    int fd = socket(family, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    struct sockaddr_storage ss = {0}; socklen_t len;
    if (family == AF_INET) {
        struct sockaddr_in *a = (struct sockaddr_in *)&ss; a->sin_family = AF_INET; a->sin_port = htons(port);
        inet_pton(AF_INET, addr, &a->sin_addr); len = sizeof(*a);
    } else {
        struct sockaddr_in6 *a = (struct sockaddr_in6 *)&ss; a->sin6_family = AF_INET6; a->sin6_port = htons(port);
        inet_pton(AF_INET6, addr, &a->sin6_addr); len = sizeof(*a);
    }
    BOOL ok = connect(fd, (struct sockaddr *)&ss, len) == 0;
    close(fd);
    return ok;
}

BOOL LHPortListening(NSInteger port) { return Connects("127.0.0.1", AF_INET, port) || Connects("::1", AF_INET6, port); }

/// The pid macOS holds responsible for another: the app a helper or a terminal child belongs to.
static pid_t Responsible(pid_t pid) {
    static pid_t (*fn)(pid_t);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid"); });
    pid_t r = fn ? fn(pid) : pid;
    return r > 0 ? r : pid;
}

static NSArray<NSString *> *ProcessArgs(pid_t pid) {
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size < sizeof(int)) return @[];
    char *buf = malloc(size);
    if (sysctl(mib, 3, buf, &size, NULL, 0) != 0) { free(buf); return @[]; }
    int argc = 0; memcpy(&argc, buf, sizeof(int));
    char *p = buf + sizeof(int), *end = buf + size;
    while (p < end && *p) p++;            // skip exec path
    while (p < end && !*p) p++;           // skip padding
    NSMutableArray *args = [NSMutableArray new];
    for (int i = 0; i < argc && p < end; i++) {
        NSString *a = [NSString stringWithUTF8String:p];
        if (a) [args addObject:a];
        p += strlen(p) + 1;
    }
    free(buf);
    return args;
}

static NSString *ProcessCwd(pid_t pid) {
    struct proc_vnodepathinfo v;
    if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &v, sizeof(v)) != sizeof(v)) return nil;
    return v.pvi_cdir.vip_path[0] ? @(v.pvi_cdir.vip_path) : nil;
}

static NSString *ProcessPath(pid_t pid) {
    char buf[PROC_PIDPATHINFO_MAXSIZE];
    return proc_pidpath(pid, buf, sizeof(buf)) > 0 ? @(buf) : @"";
}

static uint64_t StartTime(pid_t pid) {
    struct proc_bsdinfo bi;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof(bi)) != sizeof(bi)) return 0;
    return bi.pbi_start_tvsec;
}

#pragma mark - Model

@implementation LHIgnored @end

@implementation LHHost

- (NSInteger)port {
    for (NSNumber *p in self.ports) if (p.integerValue < 49152) return p.integerValue;
    return [self.ports.firstObject integerValue];
}

- (NSString *)project {
    NSString *top = self.worktree ?: self.repo;   // a worktree by its folder name, which is what you see in Finder
    if (top) return self.subdir.length ? [NSString stringWithFormat:@"%@/%@", top, self.subdir] : top;
    if (!self.cwd.length || [self.cwd isEqualToString:@"/"]) return self.name;
    return self.cwd.stringByAbbreviatingWithTildeInPath;
}

- (NSString *)url {
    NSString *h = [self.bind isEqualToString:@"::1"] ? @"[::1]" : @"localhost";
    return [NSString stringWithFormat:@"http://%@:%ld", h, (long)self.port];
}

- (NSString *)command {
    NSArray<NSString *> *a = self.wrapperArgs.count ? self.wrapperArgs : self.args;
    // npm and others rewrite their process title into argv[0] and blank the rest.
    if (a.count && [a[0] containsString:@" "] && [[a subarrayWithRange:NSMakeRange(1, a.count - 1)] indexOfObjectPassingTest:^BOOL(NSString *x, NSUInteger i, BOOL *stop) { return x.length > 0; }] == NSNotFound)
        return a[0];
    NSUInteger extra = [a indexOfObject:@"-extra"];                // BEAM: what follows -extra is what was run
    if (!self.wrapperArgs.count && [self.name isEqualToString:@"beam.smp"] && extra != NSNotFound && extra + 1 < a.count)
        a = [a subarrayWithRange:NSMakeRange(extra + 1, a.count - extra - 1)];
    if (a.count > 1 && [@[@"node", @"bun"] containsObject:a[0].lastPathComponent] &&
        [@[@"npm", @"pnpm", @"yarn", @"npx", @"pnpx", @"bun"] containsObject:[a[1].lastPathComponent stringByDeletingPathExtension]])
        a = [@[[a[1].lastPathComponent stringByDeletingPathExtension]] arrayByAddingObjectsFromArray:[a subarrayWithRange:NSMakeRange(2, a.count - 2)]];
    NSMutableArray *q = [NSMutableArray new];
    for (NSString *s in a) [q addObject:LHShellQuote(s)];
    return [q componentsJoinedByString:@" "];
}

- (NSString *)restartCommand {
    NSString *dir = self.wrapperArgs.count ? self.wrapperCwd : self.cwd;
    return dir.length ? [NSString stringWithFormat:@"cd %@ && %@", LHShellQuote(dir), self.command] : self.command;
}

- (NSDictionary *)json {
    static NSString *const states[] = { @"active", @"recent", @"idle" };
    NSDate *now = NSDate.date;
    return @{@"key": self.key, @"pid": @(self.pid), @"name": self.name, @"ports": self.ports, @"port": @(self.port),
             @"bind": self.bind ?: @"", @"url": self.url, @"kind": self.kind, @"framework": self.framework,
             @"project": self.project, @"cwd": self.cwd ?: @"", @"repo": self.repo ?: NSNull.null,
             @"branch": self.branch ?: NSNull.null, @"worktree": self.worktree ?: NSNull.null,
             @"command": self.command, @"launcher": self.launcher ?: @"", @"agent": self.agent ?: NSNull.null,
             @"orphaned": @(self.orphaned), @"uptimeSeconds": @(round([now timeIntervalSinceDate:self.started])),
             @"cpu": @(round(self.cpuPercent * 10) / 10), @"cpuSeconds": @(round(self.cpuSeconds)), @"memoryBytes": @(self.memory),
             @"energyWh": @(round(self.energyJoules / 3.6) / 1000), @"idleCPUSeconds": @(round(self.idleCPUSeconds)),
             @"idleEnergyWh": @(round(self.idleJoules / 3.6) / 1000), @"duplicates": self.duplicates ?: @[],
             @"processes": @(self.processCount), @"connections": @(self.connections), @"newConnections": @(self.newConnections), @"busy": @(self.busy), @"clients": self.clients ?: @[],
             @"state": states[self.state], @"lastActiveSecondsAgo": self.lastActive ? @(round([now timeIntervalSinceDate:self.lastActive])) : NSNull.null,
             @"watchedSeconds": @(round([now timeIntervalSinceDate:self.firstSeen])), @"title": self.title ?: NSNull.null,
             @"httpStatus": @(self.httpStatus), @"protected": @(self.isProtected)};
}

@end

#pragma mark - Detection

/// What kind of server this is, from its name and command line.
static void Detect(NSString *name, NSArray<NSString *> *args, NSArray<NSNumber *> *ports, NSString **framework, NSString **kind) {
    NSString *cmd = [[args componentsJoinedByString:@" "] lowercaseString];
    BOOL (^has)(NSString *) = ^BOOL(NSString *s) { return [cmd containsString:s]; };
    NSString *n = name.lowercaseString;
    *kind = @"dev";
    NSDictionary<NSString *, NSString *> *services = @{
        @"postgres": @"Postgres", @"mysqld": @"MySQL", @"mariadbd": @"MariaDB", @"redis-server": @"Redis",
        @"valkey-server": @"Valkey", @"mongod": @"MongoDB", @"memcached": @"Memcached", @"epmd": @"Erlang port mapper",
        @"ollama": @"Ollama", @"com.docker.backend": @"Docker", @"vpnkit-bridge": @"Docker", @"orbstack helper": @"OrbStack",
        @"clickhouse": @"ClickHouse", @"meilisearch": @"Meilisearch", @"typesense-server": @"Typesense", @"minio": @"MinIO",
        @"mailpit": @"Mailpit", @"mailhog": @"MailHog", @"caddy": @"Caddy", @"nginx": @"nginx", @"httpd": @"Apache",
        @"lm studio": @"LM Studio", @"tailscaled": @"Tailscale", @"cloudflared": @"cloudflared"};
    if (services[n]) { *framework = services[n]; *kind = @"service"; return; }
    if ([n isEqualToString:@"beam.smp"]) {
        *framework = has(@"phx.server") ? @"Phoenix" : has(@" mix test") ? @"mix test" : has(@"iex") ? @"IEx" : @"BEAM";
        if (has(@"phx.server") && has(@" iex")) *framework = @"Phoenix (IEx)";
    } else if ([n hasPrefix:@"node"] || [n isEqualToString:@"bun"] || [n isEqualToString:@"deno"]) {
        NSArray *rules = @[@[@"next-server", @"Next.js"], @[@"/next/dist", @"Next.js"], @[@".bin/next", @"Next.js"], @[@"next dev", @"Next.js"],
                           @[@"storybook", @"Storybook"], @[@"astro", @"Astro"], @[@"nuxi", @"Nuxt"], @[@"nuxt", @"Nuxt"],
                           @[@"remix", @"Remix"], @[@"sanity", @"Sanity Studio"], @[@"wrangler", @"Wrangler"], @[@"netlify", @"Netlify Dev"],
                           @[@"vercel", @"Vercel Dev"], @[@"vite", @"Vite"], @[@"webpack", @"webpack"], @[@"react-scripts", @"Create React App"],
                           @[@"expo", @"Expo"], @[@"metro", @"Metro"], @[@"docusaurus", @"Docusaurus"], @[@"eleventy", @"Eleventy"],
                           @[@"mcp", @"MCP server"], @[@"nodemon", @"Node (nodemon)"], @[@"tsx", @"Node (tsx)"], @[@"ts-node", @"Node (ts-node)"]];
        NSString *hit = nil;
        for (NSArray *r in rules) if (!hit && has(r[0])) hit = r[1];
        *framework = hit ?: [n isEqualToString:@"bun"] ? @"Bun" : [n isEqualToString:@"deno"] ? @"Deno" : @"Node";
    } else if ([n hasPrefix:@"python"] || [n hasPrefix:@"uvicorn"] || [n hasPrefix:@"gunicorn"]) {
        NSArray *rules = @[@[@"uvicorn", @"Uvicorn"], @[@"gunicorn", @"Gunicorn"], @[@"runserver", @"Django"], @[@"flask", @"Flask"],
                           @[@"http.server", @"Python http.server"], @[@"jupyter", @"Jupyter"], @[@"streamlit", @"Streamlit"],
                           @[@"gradio", @"Gradio"], @[@"mkdocs", @"MkDocs"], @[@"fastapi", @"FastAPI"], @[@"mcp", @"MCP server"]];
        NSString *hit = nil;
        for (NSArray *r in rules) if (!hit && has(r[0])) hit = r[1];
        *framework = hit ?: @"Python";
    } else if ([n hasPrefix:@"ruby"] || [n isEqualToString:@"puma"] || has(@"rails")) {
        *framework = has(@"rails") || has(@"puma") ? @"Rails" : has(@"jekyll") ? @"Jekyll" : @"Ruby";
    } else if ([n hasPrefix:@"php"]) {
        *framework = has(@"artisan") ? @"Laravel" : @"PHP";
    } else if ([n isEqualToString:@"java"]) {
        *framework = has(@"elasticsearch") ? @"Elasticsearch" : has(@"spring") ? @"Spring" : has(@"gradle") ? @"Gradle" : @"Java";
        if (has(@"elasticsearch")) *kind = @"service";
    } else if ([@[@"hugo", @"zola", @"jekyll", @"air", @"cargo", @"trunk", @"turbo"] containsObject:n]) {
        *framework = name;
    } else {
        *framework = name;
    }
    BOOL onlyEphemeral = YES;   // a server you browse to has a port you picked; random high ports are internal
    for (NSNumber *p in ports) if (p.integerValue < 49152) onlyEphemeral = NO;
    if (onlyEphemeral) *kind = @"other";
}

static NSDictionary<NSString *, NSString *> *AgentNames(void) {
    return @{@"claude": @"Claude Code", @"codex": @"Codex", @"opencode": @"OpenCode", @"gemini": @"Gemini CLI", @"aider": @"Aider",
             @"amp": @"Amp", @"goose": @"Goose", @"droid": @"Droid", @"crush": @"Crush", @"cursor-agent": @"Cursor Agent",
             @"qwen": @"Qwen Code", @"kimi": @"Kimi", @"kilo": @"Kilo", @"cline": @"Cline", @"copilot": @"Copilot CLI",
             @"auggie": @"Auggie", @"junie": @"Junie", @"doey": @"Doey"};
}

/// Package manager runners that start one script. Task runners that start several (turbo, nx, concurrently) are not wrappers:
/// stopping one would stop its other servers too.
static NSSet *Wrappers(void) { return [NSSet setWithArray:@[@"npm", @"pnpm", @"yarn", @"bun", @"bunx", @"npx", @"pnpx"]]; }
static NSSet *Shells(void) { return [NSSet setWithArray:@[@"sh", @"bash", @"zsh", @"dash"]]; }
static NSSet *Multiplexers(void) { return [NSSet setWithArray:@[@"tmux", @"screen", @"zellij", @"abduco", @"dtach"]]; }

/// The tool a process runs as: argv[0]'s basename, or the script that node or bun runs.
static NSString *ToolName(NSString *name, NSArray<NSString *> *args) {
    NSString *base = [[[args.firstObject componentsSeparatedByString:@" "].firstObject lastPathComponent] ?: name copy];
    if (!([base isEqualToString:@"node"] || [base isEqualToString:@"bun"]) || args.count < 2) return base;
    NSString *script = args[1];
    if ([script containsString:@"@anthropic-ai/claude-code"]) return @"claude";
    if ([script containsString:@"@openai/codex"]) return @"codex";
    NSString *s = script.lastPathComponent;
    if ([@[@"js", @"cjs", @"mjs"] containsObject:s.pathExtension]) s = s.stringByDeletingPathExtension;
    return ([Wrappers() containsObject:s] || AgentNames()[s]) ? s : base;
}

/// "pnpm dev --port 3300": the wrapper and the first three words after it.
static NSString *WrapperLabel(NSString *tool, NSArray<NSString *> *args) {
    NSMutableArray *words = [NSMutableArray new];
    for (NSString *a in args) [words addObjectsFromArray:[a componentsSeparatedByString:@" "]];
    NSUInteger at = [words indexOfObjectPassingTest:^BOOL(NSString *w, NSUInteger i, BOOL *stop) {
        return [[w.lastPathComponent stringByDeletingPathExtension] isEqualToString:tool]; }];
    if (at == NSNotFound) return tool;
    NSArray *rest = [words subarrayWithRange:NSMakeRange(at + 1, MIN(3, words.count - at - 1))];
    return [[@[tool] arrayByAddingObjectsFromArray:rest] componentsJoinedByString:@" "];
}

#pragma mark - Git

/// Reads repo, root, subdir, branch, worktree and touched for a folder. Can block: macOS holds file reads in
/// Documents, Desktop and Downloads until the user answers the privacy prompt.
static NSDictionary *ReadGit(NSString *cwd) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableDictionary *info = nil;
    for (NSString *d = cwd; d.length > 1; d = d.stringByDeletingLastPathComponent) {
        NSString *dotgit = [d stringByAppendingPathComponent:@".git"];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dotgit isDirectory:&isDir]) continue;
        info = [NSMutableDictionary new];
        NSString *gitdir = dotgit, *repoName = d.lastPathComponent;
        if (!isDir) {
            NSString *line = [[NSString stringWithContentsOfFile:dotgit encoding:NSUTF8StringEncoding error:nil]
                              stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if ([line hasPrefix:@"gitdir:"]) {
                gitdir = [[line substringFromIndex:7] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (!gitdir.isAbsolutePath) gitdir = [[d stringByAppendingPathComponent:gitdir] stringByStandardizingPath];
                NSRange r = [gitdir rangeOfString:@"/.git/worktrees/"];
                if (r.location != NSNotFound) {
                    repoName = [[gitdir substringToIndex:r.location] lastPathComponent];
                    info[@"worktree"] = d.lastPathComponent;
                }
            }
        }
        info[@"repo"] = repoName; info[@"root"] = d;
        info[@"subdir"] = cwd.length > d.length ? [cwd substringFromIndex:d.length + 1] : @"";
        NSString *head = [[NSString stringWithContentsOfFile:[gitdir stringByAppendingPathComponent:@"HEAD"] encoding:NSUTF8StringEncoding error:nil]
                          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([head hasPrefix:@"ref: refs/heads/"]) info[@"branch"] = [head substringFromIndex:16];
        else if (head.length >= 7) info[@"branch"] = [NSString stringWithFormat:@"detached %@", [head substringToIndex:7]];
        NSDate *m = [fm attributesOfItemAtPath:[gitdir stringByAppendingPathComponent:@"index"] error:nil].fileModificationDate;
        if (m) info[@"touched"] = m;
        break;
    }
    return info;
}

/// GitInfo never blocks the caller. A miss or a stale entry is read on a background queue and shows up on a later
/// sample; until then the last known answer, or nil, is returned. Entries refresh after 30 s.
static NSDictionary *GitInfo(NSString *cwd) {
    static NSMutableDictionary *cache; static NSMutableSet *pending; static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; pending = [NSMutableSet new]; q = dispatch_queue_create("locohost.git", DISPATCH_QUEUE_SERIAL); });
    if (!cwd.length) return nil;
    NSDictionary *hit;
    @synchronized (cache) {
        hit = cache[cwd];
        if ((!hit || -[hit[@"at"] timeIntervalSinceNow] >= 30) && ![pending containsObject:cwd]) {
            [pending addObject:cwd];
            dispatch_async(q, ^{
                NSDictionary *info = ReadGit(cwd);
                @synchronized (cache) { cache[cwd] = @{@"at": NSDate.date, @"info": info ?: NSNull.null}; [pending removeObject:cwd]; }
            });
        }
    }
    return hit[@"info"] == NSNull.null ? nil : hit[@"info"];
}

#pragma mark - Sockets

typedef struct { pid_t pid; int state; uint16_t lport, fport; BOOL floop; char laddr[INET6_ADDRSTRLEN]; } LHSock;

static BOOL V4Loop(struct in_addr a) { return (ntohl(a.s_addr) >> 24) == 127; }

static void ScanSockets(NSArray<NSNumber *> *pids, NSMutableData *out) {
    for (NSNumber *n in pids) {
        pid_t pid = n.intValue;
        int size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
        if (size <= 0) continue;
        struct proc_fdinfo *fds = malloc(size);
        size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, size);
        for (int i = 0; i < size / (int)sizeof(struct proc_fdinfo); i++) {
            if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
            struct socket_fdinfo si;
            if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &si, sizeof(si)) != sizeof(si)) continue;
            if (si.psi.soi_kind != SOCKINFO_TCP) continue;
            struct tcp_sockinfo *t = &si.psi.soi_proto.pri_tcp;
            if (t->tcpsi_state != TCPS_LISTEN && t->tcpsi_state != TCPS_ESTABLISHED) continue;
            struct in_sockinfo *in = &t->tcpsi_ini;
            LHSock s = {0};
            s.pid = pid; s.state = t->tcpsi_state;
            s.lport = ntohs(in->insi_lport); s.fport = ntohs(in->insi_fport);
            if (in->insi_vflag & INI_IPV6) {
                struct in6_addr *l = &in->insi_laddr.ina_6, *f = &in->insi_faddr.ina_6;
                if (IN6_IS_ADDR_UNSPECIFIED(l)) strcpy(s.laddr, "*");
                else if (IN6_IS_ADDR_V4MAPPED(l)) inet_ntop(AF_INET, &l->s6_addr[12], s.laddr, sizeof(s.laddr));
                else inet_ntop(AF_INET6, l, s.laddr, sizeof(s.laddr));
                s.floop = IN6_IS_ADDR_LOOPBACK(f) || (IN6_IS_ADDR_V4MAPPED(f) && f->s6_addr[12] == 127);
            } else {
                struct in_addr l = in->insi_laddr.ina_46.i46a_addr4;
                if (l.s_addr == INADDR_ANY) strcpy(s.laddr, "*");
                else inet_ntop(AF_INET, &l, s.laddr, sizeof(s.laddr));
                s.floop = V4Loop(in->insi_faddr.ina_46.i46a_addr4);
            }
            [out appendBytes:&s length:sizeof(s)];
        }
        free(fds);
    }
}

#pragma mark - Activity history

/// firstSeen and lastActive per host key, shared by the app and the CLI through activity.json.
static NSString *ActivityPath(void) { return [LHSupportDir() stringByAppendingPathComponent:@"activity.json"]; }

static NSMutableDictionary *LoadActivity(void) {
    NSData *d = [NSData dataWithContentsOfFile:ActivityPath()];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    if (![j isKindOfClass:NSMutableDictionary.class]) j = [NSMutableDictionary new];
    if (![j[@"hosts"] isKindOfClass:NSMutableDictionary.class]) j[@"hosts"] = [NSMutableDictionary new];
    return j;
}

/// Merges with what is on disk, so the CLI and the app never erase each other's observations.
static void SaveActivity(NSMutableDictionary *mine) {
    NSMutableDictionary *disk = LoadActivity();
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    for (NSString *k in mine[@"hosts"]) {
        NSMutableDictionary *a = mine[@"hosts"][k], *b = disk[@"hosts"][k];
        if (!b) { disk[@"hosts"][k] = a; continue; }
        // The waste counters belong to whichever side saw the latest activity.
        if (a[@"cpuAt"] && (!b[@"cpuAt"] || [a[@"lastActive"] doubleValue] > [b[@"lastActive"] doubleValue])) { b[@"cpuAt"] = a[@"cpuAt"]; b[@"joulesAt"] = a[@"joulesAt"]; }
        for (NSString *f in @[@"lastActive", @"lastSeen"]) if ([a[f] doubleValue] > [b[f] doubleValue]) b[f] = a[f];
        if (a[@"firstSeen"] && (!b[@"firstSeen"] || [a[@"firstSeen"] doubleValue] < [b[@"firstSeen"] doubleValue])) b[@"firstSeen"] = a[@"firstSeen"];
    }
    double since = MIN([mine[@"since"] doubleValue] ?: now, [disk[@"since"] doubleValue] ?: now);
    disk[@"since"] = @(since);
    for (NSString *k in [disk[@"hosts"] allKeys])   // a week after a host was last seen, forget it
        if (now - [disk[@"hosts"][k][@"lastSeen"] doubleValue] > 7 * 86400) [disk[@"hosts"] removeObjectForKey:k];
    [NSFileManager.defaultManager createDirectoryAtPath:LHSupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSJSONSerialization dataWithJSONObject:disk options:0 error:nil] writeToFile:ActivityPath() atomically:YES];
    [mine setDictionary:disk];
}

#pragma mark - Scanner

@interface LHProc : NSObject
@property pid_t pid, ppid; @property uid_t uid; @property uint64_t start;
@property (copy) NSString *name;
@property double cpuNs, cpuPercent, energyNj; @property uint64_t footprint;
@end
@implementation LHProc @end

@implementation LHScanner {
    NSMutableDictionary<NSNumber *, NSNumber *> *_prevCpu;
    uint64_t _prevWallNs;
    double _tbScale;
    NSMutableDictionary *_activity;
    NSMutableDictionary<NSString *, NSDictionary *> *_probes;   // "key:port" -> {status, title, at}
    NSMutableDictionary<NSString *, NSSet *> *_prevConns;       // key -> connections seen last sample, "lport-fport"
    NSMutableDictionary<NSString *, NSNumber *> *_busyStreak;   // key -> samples in a row above the CPU bar
    NSDate *_lastSave;
}

- (instancetype)init {
    if ((self = [super init])) {
        mach_timebase_info_data_t tb; mach_timebase_info(&tb);
        _tbScale = (double)tb.numer / tb.denom;
        _prevCpu = [NSMutableDictionary new];
        _probes = [NSMutableDictionary new];
        _prevConns = [NSMutableDictionary new];
        _busyStreak = [NSMutableDictionary new];
        _activity = LoadActivity();
        _idleSeconds = 30 * 60;
    }
    return self;
}

- (NSDate *)watchingSince {
    double s = [_activity[@"since"] doubleValue];
    return s ? [NSDate dateWithTimeIntervalSince1970:s] : NSDate.date;
}

+ (BOOL)alive:(LHHost *)h {
    return kill(h.pid, 0) == 0 && StartTime(h.pid) == (uint64_t)h.started.timeIntervalSince1970;
}

- (void)sample {
    uint64_t now = mach_absolute_time() * _tbScale;
    double wallDelta = _prevWallNs ? (double)(now - _prevWallNs) : 0;
    uid_t me = getuid(); pid_t self_ = getpid();

    int n = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0) / sizeof(pid_t) + 64;
    pid_t *pids = calloc(n, sizeof(pid_t));
    n = proc_listpids(PROC_ALL_PIDS, 0, pids, n * sizeof(pid_t)) / sizeof(pid_t);
    NSMutableDictionary<NSNumber *, LHProc *> *procs = [NSMutableDictionary dictionaryWithCapacity:n];
    NSMutableDictionary<NSNumber *, NSMutableArray *> *kids = [NSMutableDictionary new];
    NSMutableArray<NSNumber *> *mine = [NSMutableArray new];
    NSMutableDictionary *cpuNow = [NSMutableDictionary new];
    for (int i = 0; i < n; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;
        struct proc_bsdinfo bi;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof(bi)) != sizeof(bi)) continue;
        LHProc *p = [LHProc new];
        p.pid = pid; p.ppid = bi.pbi_ppid; p.uid = bi.pbi_uid; p.start = bi.pbi_start_tvsec;
        p.name = [NSString stringWithUTF8String:bi.pbi_name[0] ? bi.pbi_name : bi.pbi_comm] ?: @"?";
        if (p.uid == me) {
            struct rusage_info_v6 ru;
            if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ru) == 0) {
                p.cpuNs = (ru.ri_user_time + ru.ri_system_time) * _tbScale;
                p.footprint = ru.ri_phys_footprint;
                p.energyNj = ru.ri_energy_nj;
                NSNumber *prev = _prevCpu[@(pid)];
                p.cpuPercent = (prev && wallDelta > 0) ? MAX(0, (p.cpuNs - prev.doubleValue) / wallDelta * 100.0) : 0;
                cpuNow[@(pid)] = @(p.cpuNs);
            }
            [mine addObject:@(pid)];
        }
        procs[@(pid)] = p;
        if (!kids[@(p.ppid)]) kids[@(p.ppid)] = [NSMutableArray new];
        [kids[@(p.ppid)] addObject:@(pid)];
    }
    free(pids);
    _prevCpu = cpuNow; _prevWallNs = now;

    NSMutableData *socks = [NSMutableData new];
    ScanSockets(mine, socks);
    const LHSock *sv = socks.bytes;
    NSUInteger sc = socks.length / sizeof(LHSock);

    // Listeners by pid. A forked worker sharing its parent's socket rolls up into the parent.
    NSMutableDictionary<NSNumber *, NSMutableDictionary<NSNumber *, NSString *> *> *listen = [NSMutableDictionary new];
    for (NSUInteger i = 0; i < sc; i++) if (sv[i].state == TCPS_LISTEN) {
        NSMutableDictionary *m = listen[@(sv[i].pid)] ?: (listen[@(sv[i].pid)] = [NSMutableDictionary new]);
        NSString *prev = m[@(sv[i].lport)], *a = @(sv[i].laddr);
        m[@(sv[i].lport)] = (!prev || [a isEqualToString:@"*"]) ? a : prev;
    }
    for (NSNumber *pid in listen.allKeys) {
        LHProc *p = procs[pid];
        for (int hops = 0; p && hops < 6; hops++) {
            p = procs[@(p.ppid)];
            if (p && listen[@(p.pid)] && [[NSSet setWithArray:listen[@(p.pid)].allKeys] intersectsSet:[NSSet setWithArray:listen[pid].allKeys]]) {
                [listen removeObjectForKey:pid]; break;
            }
        }
    }

    // Our own client sockets: the probe's server-side connections are not activity. That covers every LocoHost
    // process, so a `locohost who` from a terminal or an agent does not look like a visitor to the menu bar app.
    NSMutableSet<NSNumber *> *ours = [NSMutableSet setWithObject:@(self_)];
    for (NSNumber *pid in mine) if ([procs[pid].name isEqualToString:@"LocoHost"]) [ours addObject:pid];
    NSMutableSet<NSNumber *> *ourLocalPorts = [NSMutableSet new];
    for (NSUInteger i = 0; i < sc; i++) if ([ours containsObject:@(sv[i].pid)] && sv[i].state == TCPS_ESTABLISHED) [ourLocalPorts addObject:@(sv[i].lport)];

    NSMutableArray<LHHost *> *hosts = [NSMutableArray new];
    NSMutableArray<LHIgnored *> *ignored = [NSMutableArray new];
    NSDate *date = NSDate.date;
    LHRules *rules = LHRules.shared;
    for (NSNumber *pidN in listen) {
        pid_t pid = pidN.intValue;
        if (pid == self_) continue;
        LHProc *p = procs[pidN];
        NSArray *ports = [listen[pidN].allKeys sortedArrayUsingSelector:@selector(compare:)];
        NSString *exec = ProcessPath(pid);
        NSString *appPath = [NSRunningApplication runningApplicationWithProcessIdentifier:Responsible(pid)].bundleURL.path;
        NSString *appBundle = appPath && [exec hasPrefix:[appPath stringByAppendingString:@"/"]] ? appPath.lastPathComponent : nil;
        if ([rules ignoresName:p.name execPath:exec appBundle:appBundle]) {
            LHIgnored *ig = [LHIgnored new]; ig.pid = pid; ig.name = p.name; ig.ports = ports;
            [ignored addObject:ig]; continue;
        }
        LHHost *h = [LHHost new];
        h.pid = pid; h.ppid = p.ppid; h.name = p.name; h.execPath = exec;
        h.key = [NSString stringWithFormat:@"%d:%llu", pid, p.start];
        h.started = [NSDate dateWithTimeIntervalSince1970:p.start];
        h.args = ProcessArgs(pid); h.cwd = ProcessCwd(pid); h.ports = ports;
        h.bind = listen[pidN][@(h.port)];
        NSString *fw, *kind; Detect(p.name, h.args, ports, &fw, &kind); h.framework = fw; h.kind = kind;

        NSDictionary *g = [kind isEqualToString:@"service"] ? nil : GitInfo(h.cwd);   // a brew service's data folder sits inside Homebrew's own repo
        h.repo = g[@"repo"]; h.repoRoot = g[@"root"]; h.subdir = g[@"subdir"]; h.branch = g[@"branch"]; h.worktree = g[@"worktree"]; h.repoTouched = g[@"touched"];

        // The tree: the listener and everything below it.
        NSMutableArray *tree = [NSMutableArray arrayWithObject:pidN];
        for (NSUInteger i = 0; i < tree.count && tree.count < 500; i++) [tree addObjectsFromArray:kids[tree[i]] ?: @[]];
        double cpu = 0, cpuNs = 0, energyNj = 0; uint64_t mem = 0;
        for (NSNumber *t in tree) { LHProc *q = procs[t]; cpu += q.cpuPercent; cpuNs += q.cpuNs; mem += q.footprint; energyNj += q.energyNj; }
        h.treePids = tree; h.cpuPercent = cpu; h.cpuSeconds = cpuNs / 1e9; h.memory = mem; h.processCount = tree.count; h.energyJoules = energyNj / 1e9;

        // Who started it: package manager wrappers right above, then an agent, a shell, a multiplexer or an app.
        NSMutableArray *via = [NSMutableArray new];
        NSString *wrapper = nil;
        BOOL inWrappers = YES, owned = NO, exclusive = YES;
        LHProc *a = procs[@(p.ppid)];
        for (int hops = 0; a && a.pid > 1 && hops < 20; hops++, a = procs[@(a.ppid)]) {
            NSArray *aargs = ProcessArgs(a.pid);
            NSString *tool = ToolName(a.name, aargs);
            // The `sh -c` a package manager runs a script through belongs to the wrapper above it.
            LHProc *above = procs[@(a.ppid)];
            BOOL scriptShell = inWrappers && [Shells() containsObject:tool] && above && [Wrappers() containsObject:ToolName(above.name, ProcessArgs(above.pid))];
            if (inWrappers && ([Wrappers() containsObject:tool] || scriptShell)) {
                // Signalled on stop only while each step down to the server is its only child.
                if (exclusive && [kids[@(a.pid)] count] == 1) {
                    if (!scriptShell) { h.wrapperPid = a.pid; h.wrapperArgs = aargs; h.wrapperCwd = ProcessCwd(a.pid); }
                } else exclusive = NO;
                if (!scriptShell) wrapper = WrapperLabel(tool, aargs);
                continue;
            }
            inWrappers = NO;
            owned = YES;   // a live shell, agent, multiplexer or app holds it
            if (!h.agent && AgentNames()[tool]) { h.agent = AgentNames()[tool]; h.agentPid = a.pid; }
            else if (!h.agent && [[aargs componentsJoinedByString:@" "] containsString:@"/.claude/shell-snapshots/"]) h.agent = @"Claude Code";
            if ([Multiplexers() containsObject:tool]) { [via addObject:tool]; break; }
            if ([NSRunningApplication runningApplicationWithProcessIdentifier:a.pid]) break;
        }
        if (wrapper) [via insertObject:wrapper atIndex:0];
        if (h.agent) [via addObject:h.agent];
        pid_t resp = Responsible(pid);
        NSRunningApplication *ra = resp != pid ? [NSRunningApplication runningApplicationWithProcessIdentifier:resp] : nil;
        if (ra.localizedName && ![via containsObject:ra.localizedName]) [via addObject:ra.localizedName];
        // launchd adopts a process whose parent exits. One that was started by an app or terminal
        // (macOS still names that app as responsible) and now has no shell, agent or app above it lost its parent.
        // One that launchd itself started, such as a brew service, is responsible for itself.
        h.orphaned = !owned && resp != pid && ![kind isEqualToString:@"service"];
        if (h.orphaned) [via addObject:@"parent exited"];
        else if (!owned) [via addObject:@"launchd"];
        h.launcher = [via componentsJoinedByString:@" · "];

        // Connections: server-side established sockets on its ports, minus the ones we opened.
        // An open connection can be a browser tab nobody looks at; a new one is a request someone just made.
        NSSet *portSet = [NSSet setWithArray:ports], *treeSet = [NSSet setWithArray:tree];
        NSMutableSet *connNow = [NSMutableSet new];
        for (NSUInteger i = 0; i < sc; i++)
            if (sv[i].state == TCPS_ESTABLISHED && [treeSet containsObject:@(sv[i].pid)] && [portSet containsObject:@(sv[i].lport)] &&
                !(sv[i].floop && [ourLocalPorts containsObject:@(sv[i].fport)])) [connNow addObject:[NSString stringWithFormat:@"%u-%u", sv[i].lport, sv[i].fport]];
        NSSet *prevConns = _prevConns[h.key];
        NSMutableSet *fresh = [connNow mutableCopy];
        if (prevConns) [fresh minusSet:prevConns]; else [fresh removeAllObjects];   // the first look has nothing to compare with
        _prevConns[h.key] = connNow;
        NSCountedSet *clients = [NSCountedSet new];
        for (NSUInteger i = 0; i < sc; i++) {
            if (sv[i].state != TCPS_ESTABLISHED || !sv[i].floop || [ours containsObject:@(sv[i].pid)] || [treeSet containsObject:@(sv[i].pid)]) continue;
            if (![portSet containsObject:@(sv[i].fport)]) continue;
            // An app's helper (a browser's network process) counts as the app. A command line process counts as itself,
            // even though macOS names the terminal it was started in as responsible.
            NSString *cexec = ProcessPath(sv[i].pid), *cn = nil;
            if ([cexec containsString:@".app/"] || [cexec containsString:@".xpc/"])
                cn = [NSRunningApplication runningApplicationWithProcessIdentifier:Responsible(sv[i].pid)].localizedName;
            [clients addObject:cn ?: procs[@(sv[i].pid)].name ?: @"?"];
        }
        h.connections = connNow.count; h.newConnections = fresh.count;
        NSMutableArray *cl = [NSMutableArray new];
        for (NSString *c in clients) [cl addObject:[clients countForObject:c] > 1 ? [NSString stringWithFormat:@"%@ ×%lu", c, (unsigned long)[clients countForObject:c]] : c];
        h.clients = [cl sortedArrayUsingSelector:@selector(compare:)];

        // CPU counts as work when it is well above this server's own lifetime average, two samples in a row.
        // BEAM and file watchers spin at a steady low level that means nothing.
        NSDictionary *pr = _probes[[NSString stringWithFormat:@"%@:%ld", h.key, (long)h.port]];
        h.title = pr[@"title"]; h.httpStatus = [pr[@"status"] integerValue];
        BOOL justProbed = pr && -[pr[@"at"] timeIntervalSinceNow] < kProbeQuiet;
        double uptime = MAX(1, -h.started.timeIntervalSinceNow), baseline = h.cpuSeconds / uptime * 100;
        BOOL hot = !justProbed && wallDelta > 0 && cpu >= MAX(kBusyCPU, 3 * baseline);
        NSInteger streak = hot ? [_busyStreak[h.key] integerValue] + 1 : 0;
        _busyStreak[h.key] = @(streak);
        h.busy = streak >= 2;
        BOOL busy = (!justProbed && fresh.count > 0) || h.busy;
        NSMutableDictionary *act = _activity[@"hosts"][h.key];
        if (!act) { act = [NSMutableDictionary dictionaryWithDictionary:@{@"firstSeen": @(date.timeIntervalSince1970)}]; _activity[@"hosts"][h.key] = act; }
        act[@"lastSeen"] = @(date.timeIntervalSince1970);
        // The tree's CPU and energy counters at the last activity: what it burned since then is waste.
        if (busy || !act[@"cpuAt"]) { act[@"cpuAt"] = @(h.cpuSeconds); act[@"joulesAt"] = @(h.energyJoules); }
        if (busy) act[@"lastActive"] = @(date.timeIntervalSince1970);
        h.idleCPUSeconds = busy ? 0 : MAX(0, h.cpuSeconds - [act[@"cpuAt"] doubleValue]);
        h.idleJoules = busy ? 0 : MAX(0, h.energyJoules - [act[@"joulesAt"] doubleValue]);
        h.firstSeen = [NSDate dateWithTimeIntervalSince1970:[act[@"firstSeen"] doubleValue]];
        h.lastActive = act[@"lastActive"] ? [NSDate dateWithTimeIntervalSince1970:[act[@"lastActive"] doubleValue]] : nil;
        NSDate *quietSince = h.lastActive ?: h.firstSeen;
        h.state = busy ? LHActive : (-[quietSince timeIntervalSinceNow] >= self.idleSeconds ? LHIdle : LHRecent);
        h.isProtected = [rules protects:h];
        [hosts addObject:h];
    }
    if (!_activity[@"since"]) _activity[@"since"] = @(date.timeIntervalSince1970);
    if (!_lastSave || -[_lastSave timeIntervalSinceNow] > 30 || hosts.count != _hosts.count) { SaveActivity(_activity); _lastSave = date; }

    // Two dev servers on the same folder and branch: usually one was started again and the first one forgotten.
    for (LHHost *h in hosts) {
        if (![h.kind isEqualToString:@"dev"] || !h.cwd.length || [h.cwd isEqualToString:@"/"]) continue;
        NSMutableArray *same = [NSMutableArray new];
        for (LHHost *o in hosts)
            if (o != h && [o.kind isEqualToString:@"dev"] && [o.cwd isEqualToString:h.cwd] && (o.branch == h.branch || [o.branch isEqualToString:h.branch])) [same addObject:@(o.port)];
        if (same.count) h.duplicates = same;
    }
    _hosts = [hosts sortedArrayUsingComparator:^NSComparisonResult(LHHost *a, LHHost *b) { return [@(a.port) compare:@(b.port)]; }];
    _ignored = [ignored sortedArrayUsingComparator:^NSComparisonResult(LHIgnored *a, LHIgnored *b) { return [a.ports.firstObject compare:b.ports.firstObject]; }];
}

- (void)probeHosts:(void (^)(void))done {
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.timeoutIntervalForRequest = 2; cfg.timeoutIntervalForResource = 3;
    cfg.HTTPAdditionalHeaders = @{@"User-Agent": @"LocoHost", @"Connection": @"close"};
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    dispatch_group_t g = dispatch_group_create();
    for (LHHost *h in self.hosts) {
        if ([h.kind isEqualToString:@"service"] || h.port >= 49152) continue;
        NSString *k = [NSString stringWithFormat:@"%@:%ld", h.key, (long)h.port];
        if (_probes[k] && -[_probes[k][@"at"] timeIntervalSinceNow] < kProbeEvery) continue;
        NSString *host = [h.bind isEqualToString:@"::1"] ? @"[::1]" : [h.bind isEqualToString:@"*"] ? @"127.0.0.1" : h.bind;
        if ([host containsString:@":"] && ![host hasPrefix:@"["]) host = [NSString stringWithFormat:@"[%@]", host];
        NSURL *u = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%ld/", host, (long)h.port]];
        if (!u) continue;
        _probes[k] = @{@"at": NSDate.date};   // marks the quiet window before the answer arrives
        dispatch_group_enter(g);
        [[session dataTaskWithURL:u completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
            NSString *title = nil;
            if (data.length) {
                NSData *head = data.length > 262144 ? [data subdataWithRange:NSMakeRange(0, 262144)] : data;
                NSString *html = [[NSString alloc] initWithData:head encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:head encoding:NSISOLatin1StringEncoding];
                NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"<title[^>]*>([\\s\\S]*?)</title>" options:NSRegularExpressionCaseInsensitive error:nil];
                NSTextCheckingResult *m = html ? [re firstMatchInString:html options:0 range:NSMakeRange(0, html.length)] : nil;
                if (m) {
                    title = [[html substringWithRange:[m rangeAtIndex:1]] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    for (NSArray *e in @[@[@"&amp;", @"&"], @[@"&lt;", @"<"], @[@"&gt;", @">"], @[@"&quot;", @"\""], @[@"&#39;", @"'"], @[@"&#x27;", @"'"]])
                        title = [title stringByReplacingOccurrencesOfString:e[0] withString:e[1]];
                    title = [[title componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@" "];
                    if (title.length > 80) title = [[title substringToIndex:80] stringByAppendingString:@"…"];
                    if (!title.length) title = nil;
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                NSMutableDictionary *r = [NSMutableDictionary dictionaryWithDictionary:@{@"at": NSDate.date, @"status": @(status)}];
                if (title) r[@"title"] = title;
                self->_probes[k] = r;
                h.title = title; h.httpStatus = status;
                dispatch_group_leave(g);
            });
        }] resume];
    }
    dispatch_group_notify(g, dispatch_get_main_queue(), ^{ [session finishTasksAndInvalidate]; if (done) done(); });
}

@end
