#import <Foundation/Foundation.h>
@class LHHost;

/// rules.json: which listeners are ignored, and which hosts Close Idle never touches.
/// Written with defaults on first run; new defaults merge in on upgrade and never remove an entry of yours.
@interface LHRules : NSObject
+ (instancetype)shared;
@property (readonly) NSURL *fileURL;
- (void)reload;
/// macOS services and ordinary apps that happen to listen. They are listed as ignored, never acted on.
/// appBundle is the name of the running app the process is part of (Spotify.app), or nil for a command line process.
- (BOOL)ignoresName:(NSString *)name execPath:(NSString *)exec appBundle:(NSString *)appBundle;
/// Close Idle skips a protected host. Matched by process name, port or folder prefix.
- (BOOL)protects:(LHHost *)h;
- (BOOL)protectsPort:(NSInteger)port;
- (void)setProtected:(BOOL)on port:(NSInteger)port;
@end
