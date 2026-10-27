#import <Foundation/Foundation.h>
#import "Ports.h"

/// What the model decided about one host.
@interface LHVerdict : NSObject
@property (copy) NSString *verdict;     // in_use | idle | unsure
@property (copy) NSString *about, *reason;
@property (copy) NSString *what, *how, *why, *waste, *recommendation;   // one sentence each, from the facts LocoHost gathered
@property (copy) NSString *keepEvidence;   // the concrete fact that someone still needs it, or empty when there is none
@property BOOL judged;                     // the Eager judge decided this verdict: idle means stop, in_use means keep
@property double confidence;
@end

/// One finished review, saved to review.json so the app and the CLI share it.
@interface LHReview : NSObject
@property (strong) NSDate *at;
@property (copy) NSString *model, *error;   // model is the one that answered: haiku, gpt-6-luna, ...
@property (copy) NSString *note;           // why the first choice was skipped, for example "Haiku: usage limit reached"
@property NSInteger tokens, hostCount;
@property double seconds, costUSD;       // costUSD is the list price the CLI reports; a subscription is not billed per call
@property (strong) NSDictionary<NSString *, LHVerdict *> *verdicts;   // by host key
@property (copy) NSString *summary;      // what is going on across all hosts, in a few sentences
@property (copy) NSString *trigger;      // what woke the review: schedule, new host, long uptime, memory pressure, high load, manual
@property (copy) NSString *mode;         // idle | proactive | eager, when the review ran
@property (copy) NSString *judgeError;   // the Eager judge failed; its hosts fall back to the first verdict
@property (strong) NSArray<NSDictionary *> *actions;   // what the mode stopped after this review: port, project, framework, why
+ (instancetype)load;                    // nil when there is none
- (void)save;
@end

/// Asks a model which localhosts are in use: Claude through the claude CLI, or OpenAI's Luna through the codex CLI,
/// both on the user's own login. The model gets no tools: it reads the facts below and answers in a fixed JSON schema.
/// The model "auto" tries Haiku first and uses Luna when claude is missing, signed out or out of usage.
@interface LHReviewer : NSObject
+ (NSString *)claudePath;                // $LOCOHOST_CLAUDE, the locohost.claudePath setting, or the usual install paths
+ (NSString *)codexPath;                 // $LOCOHOST_CODEX, the locohost.codexPath setting, or the usual install paths
/// Exactly what is sent, with secrets in command lines redacted.
+ (NSArray<NSDictionary *> *)factsFor:(NSArray<LHHost *> *)hosts scanner:(LHScanner *)scanner;
/// Blocks until the CLI answers or times out. Call it off the main thread in the app.
+ (LHReview *)review:(NSArray<LHHost *> *)hosts scanner:(LHScanner *)scanner model:(NSString *)model;
/// Eager mode's second look at quiet hosts. The burden of proof is on the host: the judge keeps it only with a
/// concrete fact that someone still needs it. Replaces those hosts' verdicts in r with judged ones. Blocks.
+ (void)judge:(NSArray<LHHost *> *)hosts review:(LHReview *)r scanner:(LHScanner *)scanner model:(NSString *)model;
@end

/// Removes values that look like secrets: key=value pairs with a secret-sounding key, the value after a --token
/// style flag, passwords in URLs, and long opaque strings.
NSString *LHRedact(NSString *s);
/// What a host burned since it was last used, as sent to the model and shown by `locohost explain`.
NSDictionary *LHWasteFacts(LHHost *h);

/// The Model menu: auto, the claude aliases and luna. Anything else typed into the setting is passed through as is,
/// to codex when it starts with gpt- and to claude otherwise.
NSArray<NSArray<NSString *> *> *LHModels(void);   // [alias, label]
NSString *LHModelLabel(NSString *alias);
