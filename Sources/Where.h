#import <Foundation/Foundation.h>
#import "Ports.h"

/// Where the terminal or agent that runs a host lives, so the menu can jump there. Every key is optional.
///   kind     cmux | tmux | terminal | iterm | app
///   app      the app's name, such as "cmux", "Terminal", "Ghostty" or "Claude"
///   label    one line for people, such as "cmux › LocoHost tray monitor › Frikkern repo check"
///   tab      the tab, pane or window title when the app tells us
///   window, workspace, surface   cmux UUIDs;  target  a tmux pane id;  tty  a terminal device such as ttys003
///   pid      the app's process, for bringing it forward
/// cmux and tmux are asked through their own CLIs, Terminal and iTerm2 are matched by the terminal device of the
/// shell above the server, and anything else is the app macOS holds responsible for the process. That link survives
/// the parent exiting, so a server whose shell is gone still names the app it came from.
///
/// wait NO returns the last answer, or nil, and refreshes in the background (the app). wait YES looks now (the CLI).
NSDictionary *LHWhere(LHHost *h, BOOL wait);
/// Refreshes every host's answer in the background. The app calls it on a timer.
void LHWhereRefresh(NSArray<LHHost *> *hosts);
/// Brings the place forward: focuses the cmux tab or tmux pane, selects the Terminal or iTerm2 tab, or activates
/// the app. Terminal and iTerm2 need the user's one-time permission for LocoHost to control them. Main thread.
BOOL LHGoTo(NSDictionary *where, NSString **error);
