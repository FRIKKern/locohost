#import "Rules.h"
#import "Ports.h"

static NSDictionary *Defaults(void) {
    return @{
        @"version": @1,
        // Never closed by Close Idle. Databases and infrastructure that many projects share.
        @"protect": @{
            @"names": @[@"postgres", @"mysqld", @"mariadbd", @"redis-server", @"valkey-server", @"mongod", @"memcached",
                        @"epmd", @"ollama", @"com.docker.backend", @"vpnkit-bridge", @"OrbStack Helper", @"clickhouse",
                        @"meilisearch", @"typesense-server", @"minio", @"mailpit", @"MailHog", @"caddy", @"nginx", @"httpd",
                        @"LM Studio", @"tailscaled", @"cloudflared"],
            @"ports": @[],
            @"paths": @[]},
        @"ignore": @{
            // Listeners that are not localhosts you started. Shown as ignored, never acted on.
            @"names": @[@"rapportd", @"sharingd", @"ControlCenter", @"Spotify", @"OneDrive", @"Dropbox", @"Discord",
                        @"Slack", @"zoom.us", @"Microsoft Teams", @"Figma", @"Raycast", @"identityservicesd", @"remoted",
                        @"AirPlayXPCHelper", @"WiFiAgent", @"Creative Cloud", @"Adobe Desktop Service", @"Steam",
                        @"1Password", @"Google Drive", @"Code Helper", @"Code Helper (Plugin)", @"Cursor Helper",
                        @"Cursor Helper (Plugin)", @"Insomnia", @"MinMacs"],
            // Apps inside .app bundles whose listeners are dev infrastructure, so they are shown anyway.
            @"devApps": @[@"Docker", @"OrbStack", @"Ollama", @"Postgres", @"LM Studio", @"Herd", @"DBngin", @"MAMP", @"Local"]}};
}

@implementation LHRules {
    NSMutableDictionary *_r;
}

+ (instancetype)shared {
    static LHRules *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [LHRules new]; [s reload]; });
    return s;
}

- (NSURL *)fileURL { return [NSURL fileURLWithPath:[LHSupportDir() stringByAppendingPathComponent:@"rules.json"]]; }

static NSMutableArray *List(NSMutableDictionary *r, NSString *group, NSString *key) {
    NSMutableDictionary *g = r[group];
    if (![g isKindOfClass:NSMutableDictionary.class]) { g = [NSMutableDictionary new]; r[group] = g; }
    NSMutableArray *l = g[key];
    if (![l isKindOfClass:NSMutableArray.class]) { l = [NSMutableArray new]; g[key] = l; }
    return l;
}

- (void)reload {
    NSData *d = [NSData dataWithContentsOfURL:self.fileURL];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    BOOL changed = ![j isKindOfClass:NSMutableDictionary.class];
    _r = changed ? [NSMutableDictionary new] : j;
    NSDictionary *def = Defaults();
    for (NSString *group in @[@"protect", @"ignore"])
        for (NSString *key in def[group]) {
            NSMutableArray *l = List(_r, group, key);
            for (id v in def[group][key]) if (![l containsObject:v]) { [l addObject:v]; changed = YES; }
        }
    if (![_r[@"version"] isEqual:def[@"version"]]) { _r[@"version"] = def[@"version"]; changed = YES; }
    if (changed) [self save];
}

- (void)save {
    [NSFileManager.defaultManager createDirectoryAtPath:LHSupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *d = [NSJSONSerialization dataWithJSONObject:_r options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    [d writeToURL:self.fileURL atomically:YES];
}

- (BOOL)ignoresName:(NSString *)name execPath:(NSString *)exec appBundle:(NSString *)appBundle {
    if ([List(_r, @"ignore", @"names") containsObject:name]) return YES;
    for (NSString *p in @[@"/System/", @"/usr/libexec/", @"/usr/sbin/", @"/Library/Apple/"]) if ([exec hasPrefix:p]) return YES;
    // Part of a running app: ignored unless the app is dev infrastructure. Interpreters that ship as an
    // app bundle (Python.app) are started from a shell, belong to no running app, and are not ignored.
    if (!appBundle) return NO;
    for (NSString *dev in List(_r, @"ignore", @"devApps")) if ([appBundle hasPrefix:dev]) return NO;
    return YES;
}

- (BOOL)protects:(LHHost *)h {
    if ([List(_r, @"protect", @"names") containsObject:h.name]) return YES;
    for (NSNumber *p in h.ports) if ([self protectsPort:p.integerValue]) return YES;
    for (NSString *prefix in List(_r, @"protect", @"paths"))
        if (prefix.length && [h.cwd hasPrefix:prefix.stringByExpandingTildeInPath]) return YES;
    return NO;
}

- (BOOL)protectsPort:(NSInteger)port { return [List(_r, @"protect", @"ports") containsObject:@(port)]; }

- (void)setProtected:(BOOL)on port:(NSInteger)port {
    NSMutableArray *l = List(_r, @"protect", @"ports");
    [l removeObject:@(port)];
    if (on) [l addObject:@(port)];
    [self save];
}

@end
