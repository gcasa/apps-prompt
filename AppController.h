/* Standalone GNUstep Terminal. GPL-2.0-or-later; see COPYING. */
#import <AppKit/AppKit.h>
@class TerminalView;
@interface AppController : NSObject
{
  NSMutableArray *_windows;
  NSPanel *_preferences;
  NSWindow *_help;
  NSWindow *_lastTerminalWindow; /* owned by _windows */
  NSButton *_fontButton, *_bell, *_blink;
  NSColorWell *_foreground, *_background, *_cursor;
  NSPopUpButton *_shape;
  NSTextField *_history;
}
- (void)buildMenus;
- (void)newTerminal:(id)sender;
- (void)toggleTerminal:(id)sender;
- (BOOL)validateMenuItem:(NSMenuItem *)item;
- (void)newTerminalInDirectory:(id)sender;
- (TerminalView *)openDirectory:(NSString *)directory;
- (void)showPreferences:(id)sender;
- (void)chooseFont:(id)sender;
- (void)changeFont:(id)sender;
- (void)changeColors:(id)sender;
- (void)changeSettings:(id)sender;
- (void)restoreDefaults:(id)sender;
- (void)showHelp:(id)sender;
@end
