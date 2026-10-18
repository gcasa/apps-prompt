/*
   Project: Ycode

   Copyright (C) 2025 Free Software Foundation

   Author: Gregory Casamento

   Created: 2025-01-15

   This application is free software; you can redistribute it and/or
   modify it under the terms of the GNU General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.

   This application is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.

   You should have received a copy of the GNU General Public
   License along with this library; if not, write to the Free
   Software Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111 USA.
*/

/* Adapted for independent Terminal regression tests. */
#import <AppKit/AppKit.h>
#import "TerminalView.h"
#import "TerminalPreferences.h"
#import "AppController.h"
#ifdef TERMINAL_X11_RESIZE
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#import <GNUstepGUI/GSDisplayServer.h>
#endif
#include <math.h>
#include <signal.h>
#include <errno.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
static NSUInteger failures, checks;
static void testAssert(BOOL ok, NSString *message) {
  checks++; if (!ok) failures++;
  NSLog(@"%@: %@", ok ? @"PASS" : @"FAIL", message);
}
@interface TerminalView (Testing)

- (BOOL)cellAtRow:(NSInteger)row column:(int)column cell:(VTermScreenCell *)cell;

- (void)queueBytes:(const char *)bytes length:(size_t)length;

- (NSPasteboard *)pasteboard;
- (void)advanceBlink;
@end

@interface TerminalTestView : TerminalView
{
  NSMutableData *_captured;
}

- (NSData *)takeOutput;
@end
@implementation TerminalTestView

- (NSPasteboard *)pasteboard
{
  return [NSPasteboard pasteboardWithName:@"TerminalTerminalRegression"];
}

- (void)queueBytes:(const char *)bytes length:(size_t)length
{
  if (!_captured) _captured = [NSMutableData new];
  [_captured appendBytes:bytes length:length];
  [super queueBytes:bytes length:length];
}

- (NSData *)takeOutput
{
  NSData *result = [NSData dataWithData:_captured ? _captured : [NSData data]];
  [_captured setLength:0]; return result;
}

- (void)dealloc { [_captured release]; [super dealloc]; }
@end

static void terminalFeed(TerminalView *view, NSString *text)
{
  [view consumeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
}

static BOOL terminalWait(TerminalView *view, NSString *text)
{
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8];
  while ([deadline timeIntervalSinceNow] > 0) {
    if ([[view screenText] rangeOfString:text].location != NSNotFound) return YES;
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
  }
  return NO;
}

static void testTerminal(NSString *temporaryDirectory)
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  id savedTerminalPreferences = [[defaults objectForKey:@"TerminalSettings"] retain];
  [TerminalPreferences resetTerminalPreferences];

  TerminalTestView *view = [[TerminalTestView alloc] initWithFrame:NSMakeRect(0, 0, 800, 400)];
  testAssert(![view isRunning], @"Constructing a terminal does not start a shell");
  terminalFeed(view, @"abc\rZ\033[2;4HQ\033[1;2H\033[K");
  VTermScreenCell cell;
  [view cellAtRow:0 column:0 cell:&cell];
  testAssert(cell.chars[0] == 'Z', @"Terminal carriage return overwrites the current line");
  [view cellAtRow:0 column:1 cell:&cell];
  testAssert(cell.chars[0] == 0, @"Erase-to-end clears terminal cells");
  [view cellAtRow:1 column:3 cell:&cell];
  testAssert(cell.chars[0] == 'Q', @"ANSI absolute cursor addressing uses rows and columns");
  terminalFeed(view, @"\033[H\033[38;2;12;");
  terminalFeed(view, @"34;56;48;5;196;1;4mC");
  [view cellAtRow:0 column:0 cell:&cell];
  testAssert(cell.chars[0] == 'C' && cell.fg.rgb.red == 12 && cell.fg.rgb.green == 34
    && cell.fg.rgb.blue == 56 && cell.bg.indexed.idx == 196 && cell.attrs.bold && cell.attrs.underline,
    @"Fragmented SGR supports truecolor, indexed color, bold, and underline");
  terminalFeed(view, @"\033[0m\033[2J\033[Hnormal\033[?1049h\033[Halternate");
  testAssert([[view screenText] hasPrefix:@"alternate"], @"Full-screen applications get an alternate screen");
  terminalFeed(view, @"\033[?1049l");
  testAssert([[view screenText] hasPrefix:@"normal"], @"Leaving alternate screen restores shell contents");
  terminalFeed(view, @"\033[2J\033[H\033(0lqk\033(B");
  testAssert([[view screenText] hasPrefix:@"┌─┐"], @"DEC line drawing character set renders box characters");
  terminalFeed(view, @"\033[2J\033[H");
  NSData *unicode = [@"é中é" dataUsingEncoding:NSUTF8StringEncoding];
  NSUInteger byte;
  for (byte = 0; byte < [unicode length]; byte++)
    [view consumeData:[unicode subdataWithRange:NSMakeRange(byte, 1)]];
  testAssert([[view screenText] hasPrefix:@"é中é"], @"Split UTF-8, wide characters, and combining marks survive reads");
  terminalFeed(view, @"\033[2J\033[H1\r\n2\r\n3\r\n4\033[2;3r\033[3;1H\n");
  [view cellAtRow:0 column:0 cell:&cell];
  testAssert(cell.chars[0] == '1', @"Scrolling margins preserve the line above the region");
  [view cellAtRow:1 column:0 cell:&cell];
  testAssert(cell.chars[0] == '3', @"Scrolling margins move only the selected region");
  terminalFeed(view, @"\033[r\033[2J\033[HABC\033[1;2H\033[@X");
  testAssert([[view screenText] hasPrefix:@"AXBC"], @"Insert-character shifts terminal cells");
  terminalFeed(view, @"\033[1;2H\033[P");
  testAssert([[view screenText] hasPrefix:@"ABC"], @"Delete-character shifts terminal cells back");
  terminalFeed(view, @"\033]0;untrusted title\007\033[2J\033[Hsafe");
  testAssert([[view screenText] hasPrefix:@"safe"], @"OSC title bytes are consumed without printing escape payloads");
  int row;
  for (row = 0; row < 100; row++) terminalFeed(view, @"history\r\n");
  testAssert([[view valueForKey:@"_history"] count] > 0, @"Terminal retains bounded scrollback");
  NSScroller *historyScroller = [view valueForKey:@"_historyScroller"];
  testAssert([historyScroller knobProportion] < 1.0 && [historyScroller doubleValue] == 1.0,
    @"Terminal scrollbar follows live output when history is available");
  [historyScroller setDoubleValue:0];
  [historyScroller sendAction:[historyScroller action] to:[historyScroller target]];
  testAssert([[view valueForKey:@"_scrollOffset"] integerValue] == [[view valueForKey:@"_history"] count],
    @"Dragging the scrollbar to the top reaches the oldest retained output");
  NSInteger previousOffset = [[view valueForKey:@"_scrollOffset"] integerValue];
  terminalFeed(view, @"new output\r\n");
  testAssert([[view valueForKey:@"_scrollOffset"] integerValue] == previousOffset + 1,
    @"New output preserves the position while browsing history");
  [historyScroller setDoubleValue:1];
  [historyScroller sendAction:[historyScroller action] to:[historyScroller target]];
  testAssert([[view valueForKey:@"_scrollOffset"] integerValue] == 0,
    @"Dragging the scrollbar to the bottom returns to live output");
  terminalFeed(view, @"\033[?1049h");
  testAssert([historyScroller knobProportion] == 1.0, @"Alternate screens do not expose shell history");
  terminalFeed(view, @"\033[?1049l");
  testAssert([historyScroller knobProportion] < 1.0, @"Returning from an alternate screen restores the history scrollbar");
  terminalFeed(view, @"\033[3J\033[2J\033[H");
  testAssert([[view valueForKey:@"_history"] count] == 0 && [historyScroller knobProportion] == 1.0, @"Erase-scrollback clears retained history and disables the scrollbar");
  [view takeOutput];
  terminalFeed(view, @"\033[4;9H\033[6n");
  testAssert([[view takeOutput] isEqual:[@"\033[4;9R" dataUsingEncoding:NSUTF8StringEncoding]],
    @"Device status query returns the current terminal cursor position");
  unichar arrow = NSUpArrowFunctionKey;
  NSString *up = [NSString stringWithCharacters:&arrow length:1];
  NSEvent *upEvent = [NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
    windowNumber:0 context:nil characters:up charactersIgnoringModifiers:up isARepeat:NO keyCode:0];
  [view keyDown:upEvent];
  testAssert([[view takeOutput] isEqual:[@"\033[A" dataUsingEncoding:NSUTF8StringEncoding]],
    @"Normal cursor keys send CSI sequences");
  terminalFeed(view, @"\033[?1h");
  [view keyDown:upEvent];
  testAssert([[view takeOutput] isEqual:[@"\033OA" dataUsingEncoding:NSUTF8StringEncoding]],
    @"Application cursor mode switches keyboard sequences");
  terminalFeed(view, @"\033[?1l\033[?2004h");
  NSPasteboard *pasteboard = [view pasteboard];
  [pasteboard declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
  [pasteboard setString:@"first\nsecond" forType:NSStringPboardType];
  [view paste:nil];
  testAssert([[view takeOutput] isEqual:[@"\033[200~first\rsecond\033[201~" dataUsingEncoding:NSUTF8StringEncoding]],
    @"Bracketed paste wraps multiline clipboard text for supporting applications");
  terminalFeed(view, @"\033[?2004l\033[2J\033[Hcopy me");
  [view selectAll:nil]; [view copy:nil];
  testAssert([[pasteboard stringForType:NSStringPboardType] hasPrefix:@"copy me\n"],
    @"Terminal selection copies text without escape sequences");
  [view setValue:[NSNumber numberWithInt:-1] forKey:@"_selectionStart"];
  [view setValue:[NSNumber numberWithInt:-1] forKey:@"_selectionEnd"];
  terminalFeed(view, @"\033[2J\033[H");

  // Exercise AppKit drawing, including wide glyphs, in a real window.
  NSWindow *preview = [[NSWindow alloc] initWithContentRect:NSMakeRect(20, 20, 800, 400)
    styleMask:NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask
    backing:NSBackingStoreBuffered defer:NO];
  [preview setReleasedWhenClosed:NO]; [preview setTitle:@"Terminal Terminal"];
  [preview setContentView:view]; [preview makeKeyAndOrderFront:nil];
  terminalFeed(view, @"Terminal Terminal — ANSI / VT100\r\n\r\n\033[1mBold\033[0m  \033[4mUnderline\033[0m  \033[3mItalic\033[0m\r\n");
  for (row = 0; row < 16; row++) terminalFeed(view,
    [NSString stringWithFormat:@"\033[48;5;%dm  %2d  ", row, row]);
  terminalFeed(view, @"\033[0m\r\n\r\n\033[38;2;90;200;255mTruecolor\033[0m  UTF-8: café 中 é\r\n\r\n\033(0lqqqqqqqqqqqqqqqqqqqqk\r\nx\033(B ANSI line drawing  \033(0x\r\nmqqqqqqqqqqqqqqqqqqqqj\033(B\r\n\r\n$ ");
  [preview display];
  [view viewWillStartLiveResize];
  [preview setContentSize:[view contentSizeForColumns:92 rows:30]];
  testAssert([[view valueForKey:@"_columns"] intValue] == 92
    && [[view valueForKey:@"_rows"] intValue] == 30, @"Resize indicator uses the updated terminal grid");
#ifdef TERMINAL_X11_RESIZE
  GSDisplayServer *server = GSServerForWindow(preview);
  if ([server respondsToSelector:@selector(xDisplayRootWindow)]) {
    Display *display = (Display *)[server serverDevice];
    Window xid = (Window)[preview windowRef];
    XSizeHints hints; XWindowAttributes dimensions; long supplied;
    BOOL gotHints = XGetWMNormalHints(display, xid, &hints, &supplied)
      && XGetWindowAttributes(display, xid, &dimensions);
    testAssert(gotHints && (hints.flags & PBaseSize) && (hints.flags & PResizeInc)
      && hints.width_inc > 0 && hints.height_inc > 0
      && (dimensions.width - hints.base_width) / hints.width_inc == 92
      && (dimensions.height - hints.base_height) / hints.height_inc == 30,
      @"Window manager resize readout reports character columns and rows");
  }
#endif
  NSBitmapImageRep *resizeBitmap = [view bitmapImageRepForCachingDisplayInRect:[view bounds]];
  [view cacheDisplayInRect:[view bounds] toBitmapImageRep:resizeBitmap];
  NSData *duringResize = [resizeBitmap representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]];
  [duringResize writeToFile:[temporaryDirectory stringByAppendingPathComponent:@"resize-indicator.png"] atomically:YES];
  [view viewDidEndLiveResize];
  [preview display];
  [view cacheDisplayInRect:[view bounds] toBitmapImageRep:resizeBitmap];
  testAssert(![duringResize isEqual:[resizeBitmap representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]]],
    @"Ending live resize removes the rendered size indicator");

  if ([[[NSProcessInfo processInfo] arguments] containsObject:@"--terminal-preview"]) {
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:[view bounds]];
    [view cacheDisplayInRect:[view bounds] toBitmapImageRep:bitmap];
    [[bitmap representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]]
      writeToFile:@"/tmp/ycode-terminal-preview.png" atomically:YES];
  }
#ifndef _WIN32
  NSString *directory = [temporaryDirectory stringByAppendingPathComponent:@"Terminal Folder With Spaces"];
  [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
  NSError *error = nil;
  testAssert([view startInDirectory:directory error:&error] && error == nil, @"Launch interactive shell on a PTY");
  if ([view isRunning]) {
    int child = [[view valueForKey:@"_child"] intValue];
    testAssert([view startInDirectory:@"/" error:&error] && [[view valueForKey:@"_child"] intValue] == child,
      @"Repeated opening preserves the terminal shell");
    [view sendData:[@"stty -echo; printf '\\033[2J\\033[H'; test -t 0 && printf '%s%s\\n' TERMINAL_ISTTY _YES; pwd\r"
      dataUsingEncoding:NSUTF8StringEncoding]];
    testAssert(terminalWait(view, @"TERMINAL_ISTTY_YES") && terminalWait(view, directory),
      @"Shell has a controlling terminal and starts in the terminal directory with spaces");
    [view sendData:[@"printf '%s%s\\n' TERMINAL_TERM_ \"$TERM\"\r" dataUsingEncoding:NSUTF8StringEncoding]];
    testAssert(terminalWait(view, @"TERMINAL_TERM_xterm-256color"), @"Shell advertises the implemented terminal protocol");
    [view setFrameSize:NSMakeSize(640, 320)];
    NSString *dimensions = [NSString stringWithFormat:@"%@ %@", [view valueForKey:@"_rows"], [view valueForKey:@"_columns"]];
    [view sendData:[@"stty size\r" dataUsingEncoding:NSUTF8StringEncoding]];
    testAssert(terminalWait(view, dimensions), @"Resizing propagates row and column counts through the PTY");
    // A foreground job must receive Ctrl-C through the PTY, not terminate Terminal.
    [view sendData:[@"sleep 30\r" dataUsingEncoding:NSUTF8StringEncoding]];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    NSEvent *interrupt = [NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:NSControlKeyMask
      timestamp:0 windowNumber:[preview windowNumber] context:nil characters:@"\003"
      charactersIgnoringModifiers:@"c" isARepeat:NO keyCode:0];
    [view keyDown:interrupt];
    [view sendData:[@"printf '%s%s\\n' TERMINAL_INTERRUPT _OK\r" dataUsingEncoding:NSUTF8StringEncoding]];
    testAssert(terminalWait(view, @"TERMINAL_INTERRUPT_OK") && [view isRunning], @"Ctrl-C interrupts the job and preserves the shell");
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:@"/usr/bin/vim"]) {
      [view sendData:[@"/usr/bin/vim -Nu NONE -i NONE -n 'terminal editor.txt'\r" dataUsingEncoding:NSUTF8StringEncoding]];
      NSDate *editorDeadline = [NSDate dateWithTimeIntervalSinceNow:8];
      while (![[view valueForKey:@"_alternateScreen"] boolValue] && [editorDeadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
      testAssert([[view valueForKey:@"_alternateScreen"] boolValue], @"Vim enters its full-screen terminal mode");
      [view sendData:[@"iTerminal terminal editor test\033:wq\r" dataUsingEncoding:NSUTF8StringEncoding]];
      editorDeadline = [NSDate dateWithTimeIntervalSinceNow:8];
      while ([[view valueForKey:@"_alternateScreen"] boolValue] && [editorDeadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
      testAssert(![[view valueForKey:@"_alternateScreen"] boolValue]
        && [[NSString stringWithContentsOfFile:[directory stringByAppendingPathComponent:@"terminal editor.txt"]
          encoding:NSUTF8StringEncoding error:NULL] isEqual:@"Terminal terminal editor test\n"],
        @"An interactive Vim session edits, saves, exits, and restores the shell screen");
    }
    [view sendData:[@"exit\r" dataUsingEncoding:NSUTF8StringEncoding]];
    testAssert(terminalWait(view, @"Shell exited.") && ![view isRunning], @"Shell exit drains output and releases the PTY");
    [view restart:nil];
    testAssert([view isRunning], @"Exited shells can be restarted");
    child = [[view valueForKey:@"_child"] intValue];
    [preview close];
    testAssert(![view isRunning], @"Closing the terminal window hangs up its terminal");
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (kill(child, 0) == 0 && [deadline timeIntervalSinceNow] > 0)
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    testAssert(kill(child, 0) < 0 && errno == ESRCH, @"Terminal cleanup reaps the shell without zombies");
  }
  error = nil;
  testAssert(![view startInDirectory:[directory stringByAppendingPathComponent:@"missing"] error:&error]
    && error != nil, @"Invalid terminal directories produce a useful error");
#endif
  [preview close]; [preview release]; [view release];

  if (savedTerminalPreferences) [defaults setObject:savedTerminalPreferences forKey:@"TerminalSettings"];
  else [defaults removeObjectForKey:@"TerminalSettings"];
  [savedTerminalPreferences release];
}

static void pump(double seconds)
{
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static BOOL colorMatches(NSColor *color, double r, double g, double b)
{
  color = [color colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
  return color && fabs([color redComponent] - r) < .012 && fabs([color greenComponent] - g) < .012
    && fabs([color blueComponent] - b) < .012;
}

@interface FractionalWheel : NSObject
@end
@implementation FractionalWheel
- (CGFloat)deltaY { return 0.1; }

- (NSUInteger)modifierFlags { return NSShiftKeyMask; }
@end

static void testPreferencesAndRendering(NSString *directory)
{
  AppController *app = [AppController new];
  [app buildMenus];
  [app showPreferences:nil];
  TerminalView *terminal = [app openDirectory:directory];
  [terminal retain];
  testAssert([[terminal valueForKey:@"_columns"] intValue] == 80
    && [[terminal valueForKey:@"_rows"] intValue] == 25, @"New terminal opens with an 80 by 25 grid");
  testAssert(NSMinX([[terminal valueForKey:@"_historyScroller"] frame]) == 0,
    @"History scroller occupies the left edge");
  int child = [[terminal valueForKey:@"_child"] intValue];
  NSMenuItem *toggle = [[[NSMenuItem alloc] initWithTitle:@"" action:@selector(toggleTerminal:) keyEquivalent:@""] autorelease];
  [app validateMenuItem:toggle];
  testAssert([[toggle title] isEqual:@"Close Terminal"],@"Visible terminal menu offers Close Terminal");
  [app toggleTerminal:toggle];
  testAssert([[toggle title] isEqual:@"Open Terminal"] && ![[terminal window] isVisible] && [terminal isRunning],
    @"Close Terminal hides the window and preserves its session");
  [app toggleTerminal:toggle];
  testAssert([[toggle title] isEqual:@"Close Terminal"] && [[terminal window] isVisible]
    && [[terminal valueForKey:@"_child"] intValue] == child,@"Open Terminal restores the same shell and updates its menu title");
  NSButton *button = [app valueForKey:@"_fontButton"];
  [button performClick:nil]; pump(.1);
  NSFontManager *manager = [NSFontManager sharedFontManager];
  NSFontPanel *fontPanel = [manager fontPanel:YES];
  [fontPanel setPanelFont:[manager convertFont:[TerminalPreferences terminalFont] toSize:20] isMultiple:NO];
  [fontPanel makeKeyAndOrderFront:nil];
  [manager modifyFontViaPanel:fontPanel];
  testAssert([[TerminalPreferences terminalFont] pointSize] == 20
    && [[terminal valueForKey:@"_font"] pointSize] == 20, @"Native Fonts panel action updates and persists the live font");
  [fontPanel orderOut:nil];
  testAssert([[terminal valueForKey:@"_child"] intValue] == child, @"Font change preserves shell PID");
  [terminal sendData:[@"stty -echo; stty size\r" dataUsingEncoding:NSUTF8StringEncoding]];
  testAssert(terminalWait(terminal, [NSString stringWithFormat:@"%@ %@", [terminal valueForKey:@"_rows"],
    [terminal valueForKey:@"_columns"]]), @"Font change updates real PTY dimensions");
  [terminal stop]; [TerminalView waitForChildCleanup];
  NSColorWell *fg = [app valueForKey:@"_foreground"], *bg = [app valueForKey:@"_background"], *cursor = [app valueForKey:@"_cursor"];
  [fg activate:YES]; [[NSColorPanel sharedColorPanel] setColor:[NSColor colorWithCalibratedRed:.2 green:.8 blue:.6 alpha:1]]; [fg deactivate];
  [bg activate:YES]; [[NSColorPanel sharedColorPanel] setColor:[NSColor colorWithCalibratedRed:.1 green:.15 blue:.2 alpha:1]]; [bg deactivate];
  [cursor activate:YES]; [[NSColorPanel sharedColorPanel] setColor:[NSColor greenColor]]; [cursor deactivate];
  [[NSColorPanel sharedColorPanel] orderOut:nil];
  testAssert(colorMatches([TerminalPreferences terminalForegroundColor], .2, .8, .6)
    && colorMatches([TerminalPreferences terminalBackgroundColor], .1, .15, .2)
    && colorMatches([TerminalPreferences terminalCursorColor], 0, 1, 0), @"Native Color panel actions persist all three colors");
  terminalFeed(terminal, @"\033c\033[?25hM\r\n");
  NSPopUpButton *shape = [app valueForKey:@"_shape"];
  NSUInteger w = [[terminal valueForKey:@"_cellWidth"] unsignedIntegerValue];
  NSUInteger h = [[terminal valueForKey:@"_cellHeight"] unsignedIntegerValue];
  int s;
  for (s = 0; s <= 4; s++) {
    [shape selectItemAtIndex:s]; [shape sendAction:[shape action] to:[shape target]];
    [[terminal window] display];
    NSBitmapImageRep *bitmap = [terminal bitmapImageRepForCachingDisplayInRect:[terminal bounds]];
    [terminal cacheDisplayInRect:[terminal bounds] toBitmapImageRep:bitmap];
    NSUInteger x, y, cursorPixels = 0, textPixels = 0;
    for (y = 0; y < h * 2; y++) for (x = 0; x < w; x++) {
      NSColor *pixel = [bitmap colorAtX:x + (NSUInteger)[NSScroller scrollerWidth] y:y];
      if (colorMatches(pixel, 0, 1, 0)) cursorPixels++;
      if (colorMatches(pixel, .2, .8, .6)) textPixels++;
    }
    NSUInteger expected = s <= 1 ? w*h : s == 2 ? 2*(w+h)-4 : s == 3 ? 2*h : 2*w;
    testAssert(cursorPixels == expected, [NSString stringWithFormat:@"Rendered cursor shape %d: %lu pixels, expected %lu", s,
      (unsigned long)cursorPixels, (unsigned long)expected]);
    testAssert(textPixels > 0 && colorMatches([bitmap colorAtX:400 y:200], .1, .15, .2), @"Rendered default text/background match Color panel choices");
    [[bitmap representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]]
      writeToFile:[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"cursor-%d.png", s]] atomically:YES];
  }
  [TerminalPreferences setTerminalCursorShape:1];
  terminalFeed(terminal, @"\033[H\033[31mM\033[0m\r");
  NSBitmapImageRep *bitmap = [terminal bitmapImageRepForCachingDisplayInRect:[terminal bounds]];
  [[terminal window] display];
  [terminal cacheDisplayInRect:[terminal bounds] toBitmapImageRep:bitmap];
  NSUInteger x,y, ink = 0;
  for (y=0;y<h;y++) for(x=0;x<w;x++) if(colorMatches([bitmap colorAtX:x + (NSUInteger)[NSScroller scrollerWidth] y:y],0,0,0)) ink++;
  [[bitmap representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]] writeToFile:[directory stringByAppendingPathComponent:@"filled-ink.png"] atomically:YES];
  testAssert(ink > 0, @"Filled block redraws its character in contrasting ink");
  terminalFeed(terminal, @"\033[?25l\033[H\033[31mM\033[0m");
  [[terminal window] display];
  [terminal cacheDisplayInRect:[terminal bounds] toBitmapImageRep:bitmap];
  NSUInteger red = 0;
  for(y=0;y<h;y++) for(x=0;x<w;x++) {
    NSColor *pixel = [[bitmap colorAtX:x + (NSUInteger)[NSScroller scrollerWidth] y:y] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    if ([pixel redComponent] > .5 && [pixel greenComponent] < .2) red++;
  }
  testAssert(red > 0, @"Explicit ANSI foreground remains red after default color changes");
  int i; for (i=0;i<100;i++) terminalFeed(terminal, @"history\r\n");
  FractionalWheel *wheel = [FractionalWheel new];
  for(i=0;i<4;i++) [terminal scrollWheel:(NSEvent *)wheel];
  [wheel release];
  testAssert([[terminal valueForKey:@"_scrollOffset"] intValue] == 1, @"Fractional trackpad events accumulate into a line");
  NSTextField *history = [app valueForKey:@"_history"];
  [history setStringValue:@"0"]; [history sendAction:[history action] to:[history target]];
  testAssert([[terminal valueForKey:@"_history"] count] == 0, @"History preference zero discards existing history immediately");
  [history setStringValue:@"50001"]; [history sendAction:[history action] to:[history target]];
  testAssert([TerminalPreferences terminalScrollbackLines] == 0, @"Out of range history input rejected");
  [history setStringValue:@"50000"]; [history sendAction:[history action] to:[history target]];
  testAssert([TerminalPreferences terminalScrollbackLines] == 50000, @"Maximum history setting accepted");
  NSButton *bell = [app valueForKey:@"_bell"], *blink = [app valueForKey:@"_blink"];
  [bell setState:NSOffState]; [blink setState:NSOffState]; [app changeSettings:bell];
  TerminalView *fresh = [[TerminalView alloc] initWithFrame:NSMakeRect(0,0,600,300)];
  testAssert([[fresh valueForKey:@"_font"] pointSize] == 20 && ![[fresh valueForKey:@"_audibleBell"] boolValue]
    && ![[fresh valueForKey:@"_allowCursorBlink"] boolValue], @"New terminals inherit persisted font and bell/blink settings");
  [fresh release];
  NSTextField *columns = [app valueForKey:@"_columns"], *rows = [app valueForKey:@"_rows"];
  [columns setStringValue:@"100"]; [rows setStringValue:@"35"]; [app changeDimensions:columns];
  NSSize previousSize = [[terminal window] frame].size;
  TerminalView *sized = [app openDirectory:directory];
  testAssert([[sized valueForKey:@"_columns"] intValue] == 100 && [[sized valueForKey:@"_rows"] intValue] == 35,
    @"New sessions use the configured character columns and rows");
  testAssert(NSEqualSizes(previousSize, [[terminal window] frame].size), @"Window-size preferences preserve existing sessions");
  [[sized window] close];
  [columns setStringValue:@"100.5"]; [app changeDimensions:columns];
  [rows setStringValue:@"1001"]; [app changeDimensions:rows];
  testAssert([columns integerValue] == 100 && [rows integerValue] == 35,
    @"Fractional and out-of-range dimensions restore the saved values");
  [app showPreferences:nil];
  NSView *preferencesView = [[app valueForKey:@"_preferences"] contentView];
  [[app valueForKey:@"_preferences"] display];
  NSBitmapImageRep *preferencesBitmap = [preferencesView bitmapImageRepForCachingDisplayInRect:[preferencesView bounds]];
  [preferencesView cacheDisplayInRect:[preferencesView bounds] toBitmapImageRep:preferencesBitmap];
  [[preferencesBitmap representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]]
    writeToFile:[directory stringByAppendingPathComponent:@"preferences.png"] atomically:YES];
  NSString *executable = [[[NSProcessInfo processInfo] arguments] objectAtIndex:0];
  if (![executable isAbsolutePath]) executable = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:executable];
  const char *program = [executable fileSystemRepresentation];
  pid_t reader = fork();
  if (reader == 0) { execl(program, program, "--read-preferences", NULL); _exit(127); }
  int result = -1;
  if (reader > 0) while (waitpid(reader, &result, 0) < 0 && errno == EINTR) {}
  testAssert(result == 0, @"A separate process reloads persisted font, colors, history and bell preferences");
  [app restoreDefaults:nil];
  testAssert([TerminalPreferences terminalColumns] == 80 && [TerminalPreferences terminalRows] == 25,
    @"Restore Defaults resets new-window dimensions to 80 by 25");
  testAssert([[terminal valueForKey:@"_font"] pointSize] == 13 && [TerminalPreferences terminalScrollbackLines] == 5000
    && colorMatches([TerminalPreferences terminalCursorColor],1,0,0), @"Restore Defaults updates existing views and restores red cursor");
  [[terminal window] close]; [terminal release];
  [[app valueForKey:@"_preferences"] orderOut:nil];
  [app release];
}

static void testInitialSizeAndPrograms(NSString *directory)
{
  TerminalTestView *view = [[TerminalTestView alloc] initWithFrame:NSMakeRect(0,0,803,407)];
  NSError *error = nil;
  testAssert([view startInDirectory:directory error:&error], @"Start independent PTY dimension test");
  struct winsize size; memset(&size,0,sizeof(size));
  ioctl([[view valueForKey:@"_master"] intValue],TIOCGWINSZ,&size);
  testAssert(size.ws_row == (int)(407 / [[view valueForKey:@"_cellHeight"] doubleValue])
    && size.ws_col == (int)((803-[NSScroller scrollerWidth]) / [[view valueForKey:@"_cellWidth"] doubleValue]),
    @"Initial PTY dimensions use actual bounds, font metrics and scrollbar width");
  [view sendData:[@"stty -echo; trap 'echo RESIZE_SIGNAL' WINCH; echo READY_FOR_SIZE\r" dataUsingEncoding:NSUTF8StringEncoding]];
  testAssert(terminalWait(view,@"READY_FOR_SIZE"),@"Interactive shell ready for SIGWINCH");
  [view setFrameSize:NSMakeSize(650,350)];
  testAssert(terminalWait(view,@"RESIZE_SIGNAL"),@"Window resize signals foreground process");
  [view sendData:[@"seq 1 100 | less\r" dataUsingEncoding:NSUTF8StringEncoding]]; pump(.5);
  testAssert([[view valueForKey:@"_alternateScreen"] boolValue],@"Real less uses alternate screen");
  [view sendData:[@"q" dataUsingEncoding:NSUTF8StringEncoding]]; pump(.3);
  testAssert(![[view valueForKey:@"_alternateScreen"] boolValue],@"less exits back to normal screen");
  [view sendData:[@"top -d 1\r" dataUsingEncoding:NSUTF8StringEncoding]]; pump(1.2);
  testAssert([[view screenText] rangeOfString:@"PID"].location != NSNotFound,@"Real interactive top renders process display");
  [view setFrameSize:NSMakeSize(750,400)]; pump(.3);
  [view sendData:[@"q" dataUsingEncoding:NSUTF8StringEncoding]]; pump(.3);
  [view sendData:[@"printf 'AFTER_%s\\n' TOP\r" dataUsingEncoding:NSUTF8StringEncoding]];
  testAssert(terminalWait(view,@"AFTER_TOP"),@"top survives resize and exits to usable shell");
  [view sendData:[@"python3 -c 'import signal,time; signal.signal(signal.SIGHUP,signal.SIG_IGN); print(\"STUBBORN_JOB\",flush=True); time.sleep(60)'\r" dataUsingEncoding:NSUTF8StringEncoding]];
  testAssert(terminalWait(view,@"STUBBORN_JOB"),@"Start foreground job that ignores hangup");
  int master = [[view valueForKey:@"_master"] intValue];
  pid_t child = [[view valueForKey:@"_child"] intValue], foreground = tcgetpgrp(master);
  NSDate *start = [NSDate date]; [view stop];
  testAssert(-[start timeIntervalSinceNow] < .1,@"Session close does not block on stubborn child");
  [TerminalView waitForChildCleanup];
  testAssert(kill(child,0)<0 && errno==ESRCH,@"Stubborn session shell reaped");
  // The Linux subreaper must collect the orphaned job, not leave it to PID 1.
  NSString *stat = [NSString stringWithContentsOfFile:[NSString stringWithFormat:@"/proc/%d/stat",foreground]
    encoding:NSUTF8StringEncoding error:NULL];
  testAssert(!stat,@"Hangup-ignoring foreground job is killed and reaped without zombies");
  [view restart:nil];
  [view sendData:[@"stty -echo; python3 -c 'import tty,time; tty.setraw(0); print(\"SLOW_READER\",flush=True); time.sleep(60)'\r" dataUsingEncoding:NSUTF8StringEncoding]];
  testAssert(terminalWait(view,@"SLOW_READER"),@"Start a PTY program that stops reading input");
  NSMutableData *largePaste = [NSMutableData dataWithLength:1024*1024];
  memset([largePaste mutableBytes],'a',[largePaste length]);
  start = [NSDate date]; [view sendData:largePaste]; pump(.25);
  [view setFrameSize:NSMakeSize(780,420)];
  testAssert(-[start timeIntervalSinceNow] < 1 && [[view valueForKey:@"_pendingInput"] length] > 0,
    @"A blocked PTY reader leaves input queued while the GUI run loop and resize remain responsive");
  [view stop]; [TerminalView waitForChildCleanup];
  [view release];
}


static NSEvent *keyEvent(unichar key, NSUInteger modifiers)
{
  NSString *characters = [NSString stringWithCharacters:&key length:1];
  return [NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:modifiers timestamp:0
    windowNumber:0 context:nil characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:0];
}

static void testInputAndHistory(void)
{
  TerminalTestView *view = [[TerminalTestView alloc] initWithFrame:NSMakeRect(0,0,500,200)];
  terminalFeed(view,@"\033="); [view keyDown:keyEvent('1',NSNumericPadKeyMask)];
  testAssert([[view takeOutput] isEqual:[@"\033Oq" dataUsingEncoding:NSUTF8StringEncoding]],@"Application keypad sends SS3 keypad sequence");
  terminalFeed(view,@"\033>"); [view keyDown:keyEvent(NSF5FunctionKey,0)];
  testAssert([[view takeOutput] isEqual:[@"\033[15~" dataUsingEncoding:NSUTF8StringEncoding]],@"F5 sends xterm function key sequence");
  terminalFeed(view,@"\033[?1000h\033[?1006h");
  NSEvent *mouse = [NSEvent mouseEventWithType:NSLeftMouseDown location:NSMakePoint([NSScroller scrollerWidth]+3,3) modifierFlags:0
    timestamp:0 windowNumber:0 context:nil eventNumber:1 clickCount:1 pressure:1];
  [view mouseDown:mouse];
  NSString *report = [[[NSString alloc] initWithData:[view takeOutput] encoding:NSUTF8StringEncoding] autorelease];
  testAssert([report hasPrefix:@"\033[<0;"] && [report hasSuffix:@"M"],@"Mouse reporting emits SGR button coordinates");
  mouse = [NSEvent mouseEventWithType:NSLeftMouseDown location:NSMakePoint([NSScroller scrollerWidth]+3,3) modifierFlags:NSShiftKeyMask
    timestamp:0 windowNumber:0 context:nil eventNumber:2 clickCount:1 pressure:1];
  [view mouseDown:mouse];
  testAssert([[view takeOutput] length] == 0,@"Shift bypasses application mouse reporting for local selection");
  terminalFeed(view,@"\033[?1000l");
  int i; for(i=0;i<5100;i++) terminalFeed(view,@"retained line\r\n");
  testAssert([[view valueForKey:@"_history"] count] == 5000,@"Default scrollback retains exactly 5,000 lines under sustained output");
  [view keyDown:keyEvent(NSPageUpFunctionKey,NSShiftKeyMask)];
  testAssert([[view valueForKey:@"_scrollOffset"] intValue] > 0,@"Shift-Page Up scrolls locally");
  [view keyDown:keyEvent('x',0)];
  testAssert([[view valueForKey:@"_scrollOffset"] intValue] == 0,@"Typing returns to the live prompt");
  [view keyDown:keyEvent(NSPageUpFunctionKey,NSShiftKeyMask)];
  [[view pasteboard] declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
  [[view pasteboard] setString:@"paste" forType:NSStringPboardType]; [view paste:nil];
  testAssert([[view valueForKey:@"_scrollOffset"] intValue] == 0,@"Pasting returns to the live prompt");
  terminalFeed(view,@"\033[?1049h");
  for(i=0;i<100;i++) terminalFeed(view,@"alternate scroll\r\n");
  terminalFeed(view,@"\033[?1049l");
  testAssert([[view valueForKey:@"_history"] count] == 5000,@"Alternate screen scrolling leaves shell history intact");
  [view release];
}

// Exercise cursor painting without starting a shell or a polling timer.
@interface CursorTestView : TerminalView
{
@public
  NSUInteger fullInvalidations, partialInvalidations;
}
@end
@implementation CursorTestView
- (BOOL)isRunning { return YES; }

- (void)setNeedsDisplay:(BOOL)flag
{
  if (flag) fullInvalidations++;
  [super setNeedsDisplay:flag];
}

- (void)setNeedsDisplayInRect:(NSRect)rect
{
  partialInvalidations++;
  [super setNeedsDisplayInRect:rect];
}
@end

static BOOL cursorPixelVisible(TerminalView *view)
{
  [view setNeedsDisplay:YES];
  [[view window] display];
  NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:[view bounds]];
  [view cacheDisplayInRect:[view bounds] toBitmapImageRep:bitmap];
  return colorMatches([bitmap colorAtX:(NSUInteger)[NSScroller scrollerWidth] + 2 y:2], 1, 0, 0);
}

static NSData *renderedPixels(TerminalView *view)
{
  [view lockFocus];
  NSBitmapImageRep *bitmap = [[[NSBitmapImageRep alloc] initWithFocusedViewRect:[view bounds]] autorelease];
  [view unlockFocus];
  return [bitmap representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]];
}

static void testActiveCursor(void)
{
  testAssert([TerminalPreferences terminalCursorBlink], @"Cursor blinking is enabled by default");
  NSWindow *windows[2]; CursorTestView *views[2]; int i;
  for (i = 0; i < 2; i++) {
    windows[i] = [[NSWindow alloc] initWithContentRect:NSMakeRect(40+i*40,40,320,180)
      styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    [windows[i] setReleasedWhenClosed:NO];
    views[i] = [[CursorTestView alloc] initWithFrame:NSMakeRect(0,0,320,180)];
    [windows[i] setContentView:views[i]];
    [windows[i] makeKeyAndOrderFront:nil]; [windows[i] makeFirstResponder:views[i]];
  }
  views[0]->fullInvalidations = views[0]->partialInvalidations = 0;
  views[1]->fullInvalidations = views[1]->partialInvalidations = 0;
  [views[0] advanceBlink]; [views[1] advanceBlink];
  testAssert(views[0]->fullInvalidations == 0 && views[0]->partialInvalidations == 0,
    @"Inactive cursor blink causes no repaint");
  testAssert(views[1]->fullInvalidations == 0 && views[1]->partialInvalidations > 0,
    @"Active cursor blink repaints only its cells");
  views[1]->fullInvalidations = views[1]->partialInvalidations = 0;
  terminalFeed(views[1], @"x\b \b");
  testAssert(views[1]->fullInvalidations == 0 && views[1]->partialInvalidations > 0,
    @"Text and cursor updates request partial redraws");
  [views[0] setValue:[NSNumber numberWithBool:NO] forKey:@"_blinkOn"];
  [views[1] setValue:[NSNumber numberWithBool:NO] forKey:@"_blinkOn"];
  testAssert(cursorPixelVisible(views[0]) && !cursorPixelVisible(views[1]),
    @"Only the active terminal hides its cursor during the blink off phase");
  [windows[0] makeKeyAndOrderFront:nil];
  testAssert(cursorPixelVisible(views[0]) && cursorPixelVisible(views[1]),
    @"Switching active windows immediately restores both cursors");
  [views[0] setValue:[NSNumber numberWithBool:NO] forKey:@"_blinkOn"];
  [views[1] setValue:[NSNumber numberWithBool:NO] forKey:@"_blinkOn"];
  testAssert(!cursorPixelVisible(views[0]) && cursorPixelVisible(views[1]),
    @"Blinking follows the newly active terminal");
  [TerminalPreferences setTerminalCursorBlink:NO];
  [views[0] setValue:[NSNumber numberWithBool:NO] forKey:@"_blinkOn"];
  testAssert(cursorPixelVisible(views[0]), @"Disabling cursor blink keeps the active cursor steady");
  views[0]->fullInvalidations = views[0]->partialInvalidations = 0;
  [views[0] advanceBlink];
  testAssert(views[0]->fullInvalidations == 0 && views[0]->partialInvalidations == 0,
    @"Disabled cursor blink causes no repaint");
  terminalFeed(views[0], @"\033[5mX\033[0m");
  views[0]->fullInvalidations = views[0]->partialInvalidations = 0;
  [views[0] advanceBlink];
  testAssert(views[0]->fullInvalidations == 0 && views[0]->partialInvalidations > 0,
    @"ANSI blinking text still repaints with cursor blinking disabled");
  terminalFeed(views[0], @"\033[2J\033[H");
  [TerminalPreferences setTerminalCursorBlink:YES];
  terminalFeed(views[0], @"\033[?25l");
  testAssert(!cursorPixelVisible(views[0]), @"Application-requested hidden cursor remains hidden");
  NSArray *updates = [NSArray arrayWithObjects:
    @"\033[?25hhello", @"\rH", @"\033[2;2H中é", @"\033[2;3HX",
    @"\033[3;1H\033[4;41m   \033[0m", @"\033[3;2H\033[K",
    @"\033[?1049hother screen", @"\033[?1049l", @"\033[2J\033[H", nil];
  for (NSString *update in updates) {
    terminalFeed(views[0], update);
    [views[0] displayIfNeeded];
    NSData *partial = [[renderedPixels(views[0]) copy] autorelease];
    [views[0] setNeedsDisplay:YES]; [views[0] displayIfNeeded];
    testAssert([partial isEqual:renderedPixels(views[0])],
      @"Incremental painting matches a complete repaint (text, wide glyphs, decorations, alternate screen)");
  }
  for (i = 0; i < 2; i++) { [windows[i] close]; [views[i] release]; [windows[i] release]; }
}

static void testProfiles(NSString *directory)
{
  [TerminalPreferences selectProfile:@"Default"];
  [TerminalPreferences resetTerminalPreferences];
  [TerminalPreferences setTerminalScrollbackLines:1234];
  AppController *app = [AppController new];
  TerminalView *original = [app openDirectory:directory];
  pid_t pid = [[original valueForKey:@"_child"] intValue];
  [app showPreferences:nil];
  [[app valueForKey:@"_profileName"] setStringValue:@"Night"];
  [app saveProfileCopy:nil];
  testAssert([[TerminalPreferences selectedProfileName] isEqual:@"Night"]
    && [TerminalPreferences terminalScrollbackLines] == 1234, @"Save Copy selects an independent copy of existing settings");
  [TerminalPreferences setTerminalCursorColor:[NSColor blueColor]];
  [TerminalPreferences setTerminalAudibleBell:NO];
  [TerminalPreferences setTerminalColumns:92 rows:31];
  testAssert([[original profileName] isEqual:@"Default"] && [[original valueForKey:@"_audibleBell"] boolValue]
    && colorMatches([original valueForKey:@"_cursorColor"],1,0,0), @"Editing another profile leaves existing terminals unchanged");
  [app makeDefaultProfile:nil];
  TerminalView *night = [app openDirectory:directory];
  testAssert([[night profileName] isEqual:@"Night"] && ![[night valueForKey:@"_audibleBell"] boolValue]
    && [[night valueForKey:@"_columns"] intValue] == 92 && [[night valueForKey:@"_rows"] intValue] == 31,
    @"New windows use the default profile and its grid dimensions");
  [TerminalPreferences selectProfile:@"Default"];
  [TerminalPreferences setTerminalAudibleBell:NO];
  [TerminalPreferences selectProfile:@"Night"];
  [TerminalPreferences setTerminalAudibleBell:YES];
  testAssert(![[original valueForKey:@"_audibleBell"] boolValue] && [[night valueForKey:@"_audibleBell"] boolValue],
    @"Live profile edits update only windows assigned to that profile");
  [original setProfileName:@"Night"];
  testAssert([[original valueForKey:@"_child"] intValue] == pid && [original isRunning]
    && colorMatches([original valueForKey:@"_cursorColor"],0,0,1), @"Applying a profile preserves the running shell");
  [[app valueForKey:@"_profiles"] selectItemWithTitle:@"Default"];
  [app selectProfile:nil]; [app applyProfile:nil];
  testAssert([[night profileName] isEqual:@"Default"] && [[original profileName] isEqual:@"Night"]
    && [night isRunning], @"Apply to Current Terminal targets only the most recently active session");
  [app newTerminalWithProfile:nil];
  NSWindow *selectedWindow = [app valueForKey:@"_lastTerminalWindow"];
  testAssert([[(TerminalView *)[selectedWindow contentView] profileName] isEqual:@"Default"]
    && [[TerminalPreferences defaultProfileName] isEqual:@"Night"], @"Open New Terminal uses the selected profile without changing the default");
  [selectedWindow close];
  [night setProfileName:@"Night"];
  [[app valueForKey:@"_profiles"] selectItemWithTitle:@"Night"]; [app selectProfile:nil];
  [[app valueForKey:@"_profileName"] setStringValue:@"Evening"];
  [app renameProfile:nil];
  testAssert([[original profileName] isEqual:@"Evening"] && [[night profileName] isEqual:@"Evening"]
    && [[TerminalPreferences defaultProfileName] isEqual:@"Evening"], @"Renaming a profile preserves window assignments and the default");
  testAssert(![TerminalPreferences duplicateSelectedProfileWithName:@"default"]
    && ![TerminalPreferences duplicateSelectedProfileWithName:@"  "]
    && ![TerminalPreferences renameSelectedProfile:@"Default"], @"Invalid and duplicate names cannot overwrite profiles");
  NSString *program = [[[NSProcessInfo processInfo] arguments] objectAtIndex:0];
  if (![program isAbsolutePath]) program = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:program];
  pid_t reader = fork();
  if (reader == 0) { execl([program fileSystemRepresentation], [program fileSystemRepresentation], "--read-profiles", NULL); _exit(127); }
  int result = -1;
  if (reader > 0) while (waitpid(reader, &result, 0) < 0 && errno == EINTR) {}
  testAssert(result == 0, @"A separate process reloads named profiles, selection, default and independent settings");
  [TerminalPreferences resetTerminalPreferences];
  TerminalPreferences *base = [[[TerminalPreferences alloc] initWithProfileName:@"Default"] autorelease];
  testAssert([TerminalPreferences terminalScrollbackLines] == 5000 && [base terminalScrollbackLines] == 1234,
    @"Restore Defaults resets only the selected profile");
  testAssert([TerminalPreferences deleteSelectedProfile] && [[original profileName] isEqual:@"Default"]
    && [[night profileName] isEqual:@"Default"] && [[TerminalPreferences defaultProfileName] isEqual:@"Default"]
    && [original isRunning], @"Deleting a profile falls back to Default without ending sessions");
  testAssert(![TerminalPreferences deleteSelectedProfile] && ![TerminalPreferences renameSelectedProfile:@"Other"],
    @"The built-in Default profile remains available");
  [[original window] close]; [[night window] close];
  [[app valueForKey:@"_preferences"] orderOut:nil]; [app release];
}

int main(int argc, const char **argv)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  [NSApplication sharedApplication];
  [NSApp finishLaunching]; [NSApp activateIgnoringOtherApps:YES];
  if ([[[NSProcessInfo processInfo] arguments] containsObject:@"--read-preferences"]) {
    BOOL ok = [[TerminalPreferences terminalFont] pointSize] == 20
      && [TerminalPreferences terminalScrollbackLines] == 50000
      && [TerminalPreferences terminalColumns] == 100 && [TerminalPreferences terminalRows] == 35
      && ![TerminalPreferences terminalAudibleBell] && ![TerminalPreferences terminalCursorBlink]
      && colorMatches([TerminalPreferences terminalForegroundColor],.2,.8,.6);
    [pool drain]; return ok ? 0 : 1;
  }
  if ([[[NSProcessInfo processInfo] arguments] containsObject:@"--read-profiles"]) {
    TerminalPreferences *base = [[[TerminalPreferences alloc] initWithProfileName:@"Default"] autorelease];
    BOOL ok = [[TerminalPreferences defaultProfileName] isEqual:@"Evening"]
      && [[TerminalPreferences selectedProfileName] isEqual:@"Evening"]
      && [TerminalPreferences terminalColumns] == 92 && [base terminalColumns] == 80
      && colorMatches([TerminalPreferences terminalCursorColor],0,0,1)
      && colorMatches([base terminalCursorColor],1,0,0);
    [pool drain]; return ok ? 0 : 1;
  }
  NSString *directory = [NSString stringWithFormat:@"/tmp/terminal-tests-%d",getpid()];
  [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSMutableDictionary *savedProfiles = [NSMutableDictionary dictionary];
  NSArray *profileKeys = [NSArray arrayWithObjects:@"TerminalProfiles", @"TerminalSelectedProfile", @"TerminalDefaultProfile", nil];
  for (NSString *key in profileKeys) {
    id value = [defaults objectForKey:key]; if (value) [savedProfiles setObject:value forKey:key];
    [defaults removeObjectForKey:key];
  }
  id saved = [[defaults objectForKey:@"TerminalSettings"] retain];
  [defaults setObject:[NSDictionary dictionaryWithObjectsAndKeys:@"bad",@"fontSize", @"no-font",@"fontName",
    @"bad",@"foreground",[NSNumber numberWithInt:-1],@"scrollbackLines",nil] forKey:@"TerminalSettings"];
  testAssert([[TerminalPreferences terminalFont] pointSize] == 13 && [TerminalPreferences terminalScrollbackLines] == 5000,
    @"Corrupt saved settings fall back safely");
  [TerminalPreferences resetTerminalPreferences];
  testActiveCursor();
  testTerminal(directory);
  testInitialSizeAndPrograms(directory);
  testInputAndHistory();
  testPreferencesAndRendering(directory);
  testProfiles(directory);
  [TerminalView waitForChildCleanup];
  if (saved) [defaults setObject:saved forKey:@"TerminalSettings"]; else [defaults removeObjectForKey:@"TerminalSettings"];
  for (NSString *key in profileKeys) {
    id value = [savedProfiles objectForKey:key];
    if (value) [defaults setObject:value forKey:key]; else [defaults removeObjectForKey:key];
  }
  [defaults synchronize]; [saved release];
  NSLog(@"%lu checks, %lu failures; rendered evidence in %@",(unsigned long)checks,(unsigned long)failures,directory);
  [pool drain]; return failures ? 1 : 0;
}
