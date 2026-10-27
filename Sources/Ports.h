#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

typedef NS_ENUM(NSInteger, LHState) { LHActive = 0, LHRecent = 1, LHIdle = 2 };

/// One process that holds at least one listening TCP port, with its whole process tree rolled up.
@interface LHHost : NSObject
@property pid_t pid, ppid;
@property (copy) NSString *key;                  // "pid:start", stable while the process lives
@property (copy) NSString *name, *execPath, *cwd;
@property (strong) NSArray<NSString *> *args;
@property (strong) NSDate *started;
@property (strong) NSArray<NSNumber *> *ports;   // sorted
@property (copy) NSString *bind;                 // address of the primary port: 127.0.0.1, ::1 or *
@property (readonly) NSInteger port;             // the primary port: the lowest below 49152, else the lowest
@property (copy) NSString *kind;                 // dev | service | other
@property (copy) NSString *framework;
@property (copy) NSString *repo, *repoRoot, *subdir, *branch, *worktree;   // worktree: folder name of a linked git worktree, else nil
@property (strong) NSDate *repoTouched;          // mtime of the git index
@property double cpuPercent, cpuSeconds;         // whole tree: now, and since start
@property double energyJoules;                   // whole tree since start, from the kernel's energy counter; 0 where the Mac has none
@property uint64_t memory;                       // whole tree, physical footprint
@property NSInteger processCount;
@property (strong) NSArray<NSNumber *> *treePids;
@property (copy) NSString *launcher;             // e.g. "pnpm dev · Claude Code · cmux"
@property (copy) NSString *agent;                // a live agent above it, e.g. "Claude Code", else nil
@property pid_t agentPid;
@property BOOL orphaned;                         // the shell, terminal or agent that started it is gone
@property pid_t wrapperPid;                      // a package manager runner above it (npm, pnpm, yarn, bun), 0 none
@property (strong) NSArray<NSString *> *wrapperArgs;
@property (copy) NSString *wrapperCwd;
@property NSInteger connections;                 // established connections to its ports now, LocoHost's own not counted
@property NSInteger newConnections;              // of those, opened since the last sample: someone made a request
@property BOOL busy;                             // CPU well above its own average, two samples in a row
@property (strong) NSArray<NSString *> *clients; // apps connected to it right now
@property (strong) NSDate *firstSeen, *lastActive;
@property double idleCPUSeconds, idleJoules;     // burned since the last activity, or since first seen when there was none
@property (strong) NSArray<NSNumber *> *duplicates;   // ports of other dev servers on the same project folder and branch
@property LHState state;
@property (copy) NSString *title;                // <title> of its page, from the HTTP probe
@property NSInteger httpStatus;                  // 0 not probed or no answer
@property BOOL isProtected;
@property (readonly) NSString *project;          // repo/subdir, or the folder
@property (readonly) NSString *url;
@property (readonly) NSString *command;          // the wrapper's command when there is one, else its own
@property (readonly) NSString *restartCommand;   // cd into the folder and run the command again
- (NSDictionary *)json;
@end

/// A listener LocoHost does not list as a localhost: macOS services and ordinary apps.
@interface LHIgnored : NSObject
@property pid_t pid;
@property (copy) NSString *name;
@property (strong) NSArray<NSNumber *> *ports;
@end

/// Samples processes and sockets, builds hosts, and keeps the activity history that decides idle.
@interface LHScanner : NSObject
- (void)sample;
@property NSTimeInterval idleSeconds;            // quiet this long counts as idle (default 30 min)
@property (readonly) NSArray<LHHost *> *hosts;   // sorted by port
@property (readonly) NSArray<LHIgnored *> *ignored;
@property (readonly) NSDate *watchingSince;      // first time this Mac's activity was recorded
/// GETs / on hosts whose page title is stale. done runs on the main queue.
- (void)probeHosts:(void (^)(void))done;
/// Is the process still the one that was sampled (pid not reused)?
+ (BOOL)alive:(LHHost *)h;
@end

NSString *LHFormatBytes(uint64_t bytes);
NSString *LHDuration(NSTimeInterval seconds);    // "45s", "12m", "3h 4m", "5d 2h"
NSString *LHSupportDir(void);                    // ~/Library/Application Support/LocoHost, or $LOCOHOST_HOME
NSString *LHShellQuote(NSString *s);
BOOL LHPortListening(NSInteger port);            // anything answers a TCP connect on loopback
