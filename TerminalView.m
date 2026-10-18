/*
   Copyright (C) 2026 Free Software Foundation

   Adapted from Ycode for standalone Terminal. Distributed under the GNU General
   Public License, version 2 or (at your option) any later version.
   See COPYING for details. There is no warranty.
*/

#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 600
#endif
#import "TerminalView.h"
#import "TerminalPreferences.h"
#ifdef TERMINAL_X11_RESIZE
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#import <GNUstepGUI/GSDisplayServer.h>
#endif
#include <math.h>
#include <errno.h>
#include <string.h>
#ifndef _WIN32
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <pwd.h>
#ifdef __linux__
#include <sys/prctl.h>
#include <dirent.h>
#endif
#endif

@interface TerminalView (Private)

- (void)poll:(NSTimer *)timer;

- (void)queueBytes:(const char *)bytes length:(size_t)length;

- (int)property:(VTermProp)property value:(VTermValue *)value;

- (int)pushLine:(int)columns cells:(const VTermScreenCell *)cells;

- (int)popLine:(int)columns cells:(VTermScreenCell *)cells;

- (void)clearHistory;

- (void)resizeTerminal;
- (void)updateResizeIndicator;
- (void)updateWindowSizeHints;

- (void)updateScroller;

- (void)scrollHistory:(NSScroller *)sender;

- (void)preferencesChanged:(NSNotification *)notification;

- (void)ringBell;
@end

static int terminalDamage(VTermRect rect, void *user)
{
  [(TerminalView *)user setNeedsDisplay:YES];
  return 1;
}
static int terminalCursor(VTermPos pos, VTermPos old, int visible, void *user)
{
  [(TerminalView *)user setNeedsDisplay:YES];
  return 1;
}
static int terminalProperty(VTermProp property, VTermValue *value, void *user)
{
  return [(TerminalView *)user property:property value:value];
}
static int terminalBell(void *user) { [(TerminalView *)user ringBell]; return 1; }
static int terminalPush(int columns, const VTermScreenCell *cells, void *user)
{
  return [(TerminalView *)user pushLine:columns cells:cells];
}
static int terminalPop(int columns, VTermScreenCell *cells, void *user)
{
  return [(TerminalView *)user popLine:columns cells:cells];
}
static int terminalClear(void *user)
{
  [(TerminalView *)user clearHistory]; return 1;
}
static void terminalOutput(const char *bytes, size_t length, void *user)
{
  [(TerminalView *)user queueBytes:bytes length:length];
}
static const VTermScreenCallbacks terminalCallbacks = {
  terminalDamage, NULL, terminalCursor, terminalProperty, terminalBell,
  NULL, terminalPush, terminalPop, terminalClear
};

static NSString *terminalCellString(const VTermScreenCell *cell)
{
  unichar text[VTERM_MAX_CHARS_PER_CELL * 2];
  NSUInteger count = 0;
  int i;
  for (i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell->chars[i]; i++) {
    uint32_t c = cell->chars[i];
    if (c == (uint32_t)-1) break;
    if (c > 0xffff && c <= 0x10ffff) {
      c -= 0x10000;
      text[count++] = 0xd800 + (c >> 10);
      text[count++] = 0xdc00 + (c & 1023);
    } else if (c <= 0xffff) text[count++] = c;
  }
  return count ? [NSString stringWithCharacters:text length:count] : @" ";
}

static VTermModifier terminalModifiers(NSEvent *event)
{
  NSUInteger flags = [event modifierFlags];
  int result = 0;
  if (flags & NSShiftKeyMask) result |= VTERM_MOD_SHIFT;
  if (flags & NSAlternateKeyMask) result |= VTERM_MOD_ALT;
  if (flags & NSControlKeyMask) result |= VTERM_MOD_CTRL;
  return (VTermModifier)result;
}

static NSCondition *cleanupCondition;
static NSUInteger cleanupCount;

@implementation TerminalView
+ (void)initialize
{
  if (self == [TerminalView class]) {
    cleanupCondition = [NSCondition new];
#ifdef __linux__
    /* Reap orphaned jobs ourselves instead of relying on desktop PID 1. */
    prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0);
#endif
  }
}

+ (void)waitForChildCleanup
{
  [cleanupCondition lock];
  while (cleanupCount) [cleanupCondition wait];
  [cleanupCondition unlock];
}


- (id)initWithFrame:(NSRect)frame
{
  if ((self = [super initWithFrame:frame])) {
    _master = _child = _session = -1;
    _selectionStart = _selectionEnd = -1;
    _cursorVisible = YES;
    _blinkOn = YES;
    _cursorShape = VTERM_PROP_CURSORSHAPE_BLOCK;
    _font = RETAIN([TerminalPreferences terminalFont]);
    _boldFont = RETAIN([[NSFontManager sharedFontManager] convertFont:_font toHaveTrait:NSBoldFontMask]);
    _cellWidth = ceil([@"M" sizeWithAttributes:[NSDictionary dictionaryWithObject:_font forKey:NSFontAttributeName]].width);
    _cellHeight = ceil([_font ascender] - [_font descender]);
    _history = [NSMutableArray new];
    _pendingInput = [NSMutableData new];
    CGFloat scrollerWidth = [NSScroller scrollerWidth];
    _historyScroller = [[NSScroller alloc] initWithFrame:NSMakeRect(0, 0,
      scrollerWidth, frame.size.height)];
    [_historyScroller setAutoresizingMask:NSViewMaxXMargin | NSViewHeightSizable];
    [_historyScroller setTarget:self];
    [_historyScroller setAction:@selector(scrollHistory:)];
    [self addSubview:_historyScroller];
    RELEASE(_historyScroller);
    _rows = MAX(2, (int)(frame.size.height / _cellHeight));
    _columns = MAX(2, (int)(MAX(0, frame.size.width - scrollerWidth) / _cellWidth));
    _terminal = vterm_new(_rows, _columns);
    vterm_set_utf8(_terminal, 1);
    vterm_output_set_callback(_terminal, terminalOutput, self);
    _screen = vterm_obtain_screen(_terminal);
    vterm_screen_set_callbacks(_screen, &terminalCallbacks, self);
    vterm_screen_enable_altscreen(_screen, 1);
    vterm_screen_set_damage_merge(_screen, VTERM_DAMAGE_SCREEN);
    vterm_screen_reset(_screen, 1);
    [self preferencesChanged:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(preferencesChanged:)
      name:TerminalPreferencesDidChangeNotification object:nil];
    [self setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  }
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [self stop];
  if (_terminal) vterm_free(_terminal);
  RELEASE(_font); RELEASE(_boldFont); RELEASE(_history);
  RELEASE(_foregroundColor); RELEASE(_backgroundColor); RELEASE(_cursorColor);
  RELEASE(_pendingInput); RELEASE(_directory);
#ifdef TERMINAL_X11_RESIZE
  if (_resizeDisplay) XCloseDisplay((Display *)_resizeDisplay);
#endif
  [super dealloc];
}

- (NSSize)contentSizeForColumns:(NSUInteger)columns rows:(NSUInteger)rows
{
  return NSMakeSize(columns * _cellWidth + [NSScroller scrollerWidth], rows * _cellHeight);
}

- (BOOL)isFlipped { return YES; }

- (void)ringBell { if (_audibleBell) NSBeep(); }

- (void)preferencesChanged:(NSNotification *)notification
{
  ASSIGN(_font, [TerminalPreferences terminalFont]);
  NSFont *bold = [[NSFontManager sharedFontManager] convertFont:_font toHaveTrait:NSBoldFontMask];
  ASSIGN(_boldFont, bold ? bold : _font);
  _cellWidth = ceil([@"M" sizeWithAttributes:[NSDictionary dictionaryWithObject:_font forKey:NSFontAttributeName]].width);
  _cellHeight = ceil([_font ascender] - [_font descender]);
  ASSIGN(_foregroundColor, [TerminalPreferences terminalForegroundColor]);
  ASSIGN(_backgroundColor, [TerminalPreferences terminalBackgroundColor]);
  ASSIGN(_cursorColor, [TerminalPreferences terminalCursorColor]);
  _preferredCursorShape = [TerminalPreferences terminalCursorShape];
  VTermColor fg, bg;
  NSColor *color = [_foregroundColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
  vterm_color_rgb(&fg, lround([color redComponent] * 255), lround([color greenComponent] * 255), lround([color blueComponent] * 255));
  color = [_backgroundColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
  vterm_color_rgb(&bg, lround([color redComponent] * 255), lround([color greenComponent] * 255), lround([color blueComponent] * 255));
  vterm_screen_set_default_colors(_screen, &fg, &bg);
  _scrollbackLimit = [TerminalPreferences terminalScrollbackLines];
  if ([_history count] > _scrollbackLimit) {
    [_history removeObjectsInRange:NSMakeRange(0, [_history count] - _scrollbackLimit)];
    _selectionStart = _selectionEnd = -1;
  }
  _scrollOffset = MIN(_scrollOffset, (NSInteger)[_history count]);
  _audibleBell = [TerminalPreferences terminalAudibleBell];
  _allowCursorBlink = [TerminalPreferences terminalCursorBlink];
  _blinkOn = YES;
  _lastBlink = [NSDate timeIntervalSinceReferenceDate];
  [self resizeTerminal];
  [self updateScroller];
  [self setNeedsDisplay:YES];
}

- (BOOL)isOpaque { return YES; }

- (BOOL)acceptsFirstResponder { return YES; }

- (BOOL)becomeFirstResponder
{
  _blinkOn = YES;
  _lastBlink = [NSDate timeIntervalSinceReferenceDate];
  [[self window] setAcceptsMouseMovedEvents:YES];
  vterm_state_focus_in(vterm_obtain_state(_terminal));
  [self setNeedsDisplay:YES]; return YES;
}

- (BOOL)resignFirstResponder
{
  vterm_state_focus_out(vterm_obtain_state(_terminal));
  [self setNeedsDisplay:YES]; return YES;
}

- (void)viewWillMoveToWindow:(NSWindow *)window
{
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  for (NSString *name in [NSArray arrayWithObjects:NSWindowWillCloseNotification,
      NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification, nil]) {
    if ([self window]) [center removeObserver:self name:name object:[self window]];
    if (window) [center addObserver:self selector:
      [name isEqual:NSWindowWillCloseNotification] ? @selector(windowClosing:) : @selector(windowFocusChanged:)
      name:name object:window];
  }
  [super viewWillMoveToWindow:window];
}

- (void)windowFocusChanged:(NSNotification *)notification
{
  // Show the cursor immediately on either side of a focus change.
  _blinkOn = YES;
  _lastBlink = [NSDate timeIntervalSinceReferenceDate];
  [self setNeedsDisplay:YES];
}

- (void)windowClosing:(NSNotification *)notification { [self stop]; }

- (BOOL)isRunning { return _master >= 0; }


- (int)property:(VTermProp)property value:(VTermValue *)value
{
  if (property == VTERM_PROP_CURSORVISIBLE) _cursorVisible = value->boolean;
  if (property == VTERM_PROP_CURSORBLINK) _cursorBlink = value->boolean;
  if (property == VTERM_PROP_CURSORSHAPE) _cursorShape = value->number;
  if (property == VTERM_PROP_ALTSCREEN) {
    _alternateScreen = value->boolean;
    _scrollOffset = 0;
    _selectionStart = _selectionEnd = -1;
  }
  if (property == VTERM_PROP_MOUSE) _mouseReporting = value->number != VTERM_PROP_MOUSE_NONE;
  // OSC titles and clipboard requests never alter the UI or pasteboard.
  [self setNeedsDisplay:YES];
  return 1;
}

- (void)clearHistory
{
  [_history removeAllObjects]; _scrollOffset = 0;
  _selectionStart = _selectionEnd = -1;
  [self setNeedsDisplay:YES];
}

- (int)pushLine:(int)columns cells:(const VTermScreenCell *)cells
{
  if (_alternateScreen || !_scrollbackLimit) return 1;
  [_history addObject:[NSData dataWithBytes:cells length:columns * sizeof(*cells)]];
  if ([_history count] > _scrollbackLimit) {
    [_history removeObjectAtIndex:0];
    _selectionStart = _selectionEnd = -1;
  }
  if (_scrollOffset) _scrollOffset = MIN((NSInteger)[_history count], _scrollOffset + 1);
  return 1;
}

- (int)popLine:(int)columns cells:(VTermScreenCell *)cells
{
  if (_alternateScreen) return 0;
  NSData *line = [_history lastObject];
  if (!line) return 0;
  memset(cells, 0, columns * sizeof(*cells));
  int col;
  for (col = 0; col < columns; col++) {
    cells[col].width = 1;
    vterm_state_get_default_colors(vterm_obtain_state(_terminal), &cells[col].fg, &cells[col].bg);
    cells[col].fg.type |= VTERM_COLOR_DEFAULT_FG;
    cells[col].bg.type |= VTERM_COLOR_DEFAULT_BG;
  }
  memcpy(cells, [line bytes], MIN([line length], columns * sizeof(*cells)));
  [_history removeLastObject];
  _scrollOffset = MIN(_scrollOffset, (NSInteger)[_history count]);
  return 1;
}

- (void)consumeData:(NSData *)data
{
  vterm_input_write(_terminal, [data bytes], [data length]);
  vterm_screen_flush_damage(_screen);
  [self updateScroller];
}

- (void)queueBytes:(const char *)bytes length:(size_t)length
{
  if (_master >= 0) [_pendingInput appendBytes:bytes length:length];
}

- (void)sendData:(NSData *)data { [self queueBytes:[data bytes] length:[data length]]; }


- (void)setFrame:(NSRect)frame
{
  BOOL resized = !NSEqualSizes([self frame].size, frame.size);
  [super setFrame:frame];
  if (_terminal && resized) [self updateResizeIndicator];
  // NSTabView uses setFrame: when installing a selected tab. GNUstep does
  // not route that change through setFrameSize:.
  if (_terminal) [self resizeTerminal];
}

- (void)setFrameSize:(NSSize)size
{
  BOOL resized = !NSEqualSizes([self frame].size, size);
  [super setFrameSize:size];
  if (_terminal && resized) [self updateResizeIndicator];
  if (_terminal) [self resizeTerminal];
}

- (BOOL)resizeMouseIsDown
{
#ifdef TERMINAL_X11_RESIZE
  if (!_resizeDisplay) _resizeDisplay = XOpenDisplay(NULL);
  if (_resizeDisplay) {
    Display *display = (Display *)_resizeDisplay;
    Window root, child;
    int rootX, rootY, x, y;
    unsigned int mask;
    if (XQueryPointer(display, DefaultRootWindow(display), &root, &child,
        &rootX, &rootY, &x, &y, &mask))
      return (mask & (Button1Mask | Button2Mask | Button3Mask)) != 0;
  }
#endif
  return [NSEvent pressedMouseButtons] != 0;
}

- (void)checkResizeEnded:(NSTimer *)timer
{
  if ([self resizeMouseIsDown]) return;
  _showResizeIndicator = NO;
  [_resizeTimer invalidate]; DESTROY(_resizeTimer);
  [self setNeedsDisplay:YES];
}

- (void)viewWillStartLiveResize
{
  [super viewWillStartLiveResize];
  [self setNeedsDisplay:YES];
}

- (void)viewDidEndLiveResize
{
  [super viewDidEndLiveResize];
  _showResizeIndicator = NO;
  [_resizeTimer invalidate]; DESTROY(_resizeTimer);
  [self setNeedsDisplay:YES];
}

- (void)updateResizeIndicator
{
  // GNUstep's X11 backend does not send live-resize callbacks. Query the
  // pointer independently of events, since the window manager owns the drag.
  if ([[self window] isVisible] && ![self inLiveResize] && [self resizeMouseIsDown]) {
    _showResizeIndicator = YES;
    if (!_resizeTimer) {
      _resizeTimer = [[NSTimer timerWithTimeInterval:0.03 target:self
        selector:@selector(checkResizeEnded:) userInfo:nil repeats:YES] retain];
      for (NSString *mode in [NSArray arrayWithObjects:NSDefaultRunLoopMode,
          NSEventTrackingRunLoopMode, NSModalPanelRunLoopMode, nil])
        [[NSRunLoop mainRunLoop] addTimer:_resizeTimer forMode:mode];
    }
  }
  [self setNeedsDisplay:YES];
}

- (void)viewDidMoveToWindow
{
  [super viewDidMoveToWindow];
  [self updateWindowSizeHints];
}

- (void)updateWindowSizeHints
{
  NSWindow *window = [self window];
  if (!window || [window contentView] != self) return;
  NSSize increments = NSMakeSize(_cellWidth, _cellHeight);
  if (!NSEqualSizes([window resizeIncrements], increments))
    [window setResizeIncrements:increments];
#ifdef TERMINAL_X11_RESIZE
  GSDisplayServer *server = GSServerForWindow(window);
  // windowRef is an XID only for the X11 backend.
  if (![server respondsToSelector:@selector(xDisplayRootWindow)]) return;
  Display *display = (Display *)[server serverDevice];
  Window xid = (Window)[window windowRef];
  XSizeHints hints;
  XWindowAttributes attributes;
  long supplied;
  if (!xid || !XGetWMNormalHints(display, xid, &hints, &supplied)
      || !XGetWindowAttributes(display, xid, &attributes)) return;
  // Exclude the scroller and any client-side decoration from the grid count.
  int baseWidth = MAX(0, attributes.width - [self bounds].size.width) + [NSScroller scrollerWidth];
  int baseHeight = MAX(0, attributes.height - [self bounds].size.height);
  if (!(hints.flags & PBaseSize) || hints.base_width != baseWidth || hints.base_height != baseHeight) {
    hints.flags |= PBaseSize;
    hints.base_width = baseWidth;
    hints.base_height = baseHeight;
    XSetWMNormalHints(display, xid, &hints);
    XFlush(display);
  }
#endif
}

- (void)resizeTerminal
{
  [self updateWindowSizeHints];
  int rows = MIN(1000, MAX(2, (int)([self bounds].size.height / _cellHeight)));
  int cols = MIN(1000, MAX(2, (int)(MAX(0, [self bounds].size.width - [NSScroller scrollerWidth]) / _cellWidth)));
  [self updateScroller];
  if (rows == _rows && cols == _columns) return;
  _rows = rows; _columns = cols;
  _selectionStart = _selectionEnd = -1;
  vterm_set_size(_terminal, rows, cols);
#ifndef _WIN32
  if (_master >= 0) {
    struct winsize size;
    memset(&size, 0, sizeof(size)); size.ws_row = rows; size.ws_col = cols;
    ioctl(_master, TIOCSWINSZ, &size);
  }
#endif
  vterm_screen_flush_damage(_screen);
  [self updateScroller];
  [self setNeedsDisplay:YES];
}


- (BOOL)startInDirectory:(NSString *)directory error:(NSError **)error
{
  // Use the final visible bounds before creating the PTY, and refresh an
  // existing session when a previously hidden tab is selected again.
  [self resizeTerminal];
  if ([self isRunning]) return YES;
  int failure = 0;
#ifndef _WIN32
  NSDictionary *environment = [[NSProcessInfo processInfo] environment];
  NSString *shell = [environment objectForKey:@"SHELL"];
  if (![shell isAbsolutePath] || ![[NSFileManager defaultManager] isExecutableFileAtPath:shell]) {
    struct passwd *user = getpwuid(getuid());
    shell = user && user->pw_shell ? [NSString stringWithUTF8String:user->pw_shell] : @"/bin/sh";
  }
  if (![[NSFileManager defaultManager] isExecutableFileAtPath:shell]) shell = @"/bin/sh";
  BOOL isDirectory = NO;
  if (![directory isAbsolutePath] || ![[NSFileManager defaultManager] fileExistsAtPath:directory isDirectory:&isDirectory]
      || !isDirectory) failure = ENOENT;
  else {
    _master = posix_openpt(O_RDWR | O_NOCTTY);
    if (_master < 0) failure = errno;
    else if (grantpt(_master) < 0 || unlockpt(_master) < 0) failure = errno;
  }
  char *slaveName = !failure ? ptsname(_master) : NULL;
  if (!failure && !slaveName) failure = errno ? errno : EIO;
  if (!failure) {
    fcntl(_master, F_SETFD, FD_CLOEXEC);
    fcntl(_master, F_SETFL, O_NONBLOCK);
    struct winsize size;
    memset(&size, 0, sizeof(size)); size.ws_row = _rows; size.ws_col = _columns;
    ioctl(_master, TIOCSWINSZ, &size);
    // Prepare all strings before fork; the child only calls POSIX functions.
    NSMutableDictionary *env = [NSMutableDictionary dictionaryWithDictionary:environment];
    [env setObject:@"xterm-256color" forKey:@"TERM"];
    [env setObject:@"truecolor" forKey:@"COLORTERM"];
    [env setObject:directory forKey:@"PWD"];
    [env removeObjectForKey:@"COLUMNS"]; [env removeObjectForKey:@"LINES"];
    char **envp = calloc([env count] + 1, sizeof(char *));
    NSEnumerator *keys = [env keyEnumerator]; NSString *key; NSUInteger index = 0;
    while ((key = [keys nextObject]) != nil)
      envp[index++] = strdup([[NSString stringWithFormat:@"%@=%@", key, [env objectForKey:key]] UTF8String]);
    char *program = strdup([shell fileSystemRepresentation]);
    char *cwd = strdup([directory fileSystemRepresentation]);
    char *slave = strdup(slaveName);
    char *argv[] = { program, "-i", NULL };
    long maxFD = sysconf(_SC_OPEN_MAX);
    if (maxFD < 0) maxFD = 1024;
    pid_t child = fork();
    if (child == 0) {
      int fd;
      unsigned int signalIndex;
      int signals[] = { SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGCHLD, SIGPIPE,
        SIGTSTP, SIGTTIN, SIGTTOU, SIGWINCH };
      sigset_t mask; sigemptyset(&mask); sigprocmask(SIG_SETMASK, &mask, NULL);
      for (signalIndex = 0; signalIndex < sizeof(signals) / sizeof(signals[0]); signalIndex++)
        signal(signals[signalIndex], SIG_DFL);
      if (setsid() < 0) _exit(126);
      fd = open(slave, O_RDWR);
      if (fd < 0) _exit(126);
      ioctl(fd, TIOCSCTTY, 0);
#ifdef IUTF8
      struct termios settings;
      if (tcgetattr(fd, &settings) == 0) { settings.c_iflag |= IUTF8; tcsetattr(fd, TCSANOW, &settings); }
#endif
      dup2(fd, 0); dup2(fd, 1); dup2(fd, 2);
      for (fd = 3; fd < maxFD; fd++) close(fd);
      if (chdir(cwd) < 0) {
        const char message[] = "Terminal: cannot enter working directory\r\n";
        write(2, message, sizeof(message) - 1); _exit(126);
      }
      execve(program, argv, envp);
      {
        const char message[] = "Terminal: cannot execute shell\r\n";
        write(2, message, sizeof(message) - 1); _exit(127);
      }
    }
    if (child < 0) failure = errno;
    else _session = _child = child;
    for (index = 0; envp[index]; index++) free(envp[index]);
    free(envp); free(program); free(cwd); free(slave);
  }
#else
  failure = ENOSYS;
#endif
  if (failure) {
#ifndef _WIN32
    if (_master >= 0) close(_master);
#endif
    _master = -1;
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:failure userInfo:nil];
    return NO;
  }
  ASSIGN(_directory, directory);
  _ended = NO;
  _blinkOn = YES;
  _lastBlink = [NSDate timeIntervalSinceReferenceDate];
  [self clearHistory];
  [_pendingInput setLength:0];
  vterm_screen_reset(_screen, 1);
  _timer = RETAIN([NSTimer timerWithTimeInterval:0.02 target:self selector:@selector(poll:) userInfo:nil repeats:YES]);
  [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSDefaultRunLoopMode];
  [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSEventTrackingRunLoopMode];
  [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSModalPanelRunLoopMode];
  return YES;
}

#ifndef _WIN32

+ (void)reapChild:(NSArray *)processes
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  pid_t child = [[processes objectAtIndex:0] intValue];
  pid_t foreground = [[processes objectAtIndex:1] intValue];
#ifdef __linux__
  (void)foreground;
#endif
  int status, attempts;
#ifdef __linux__
  /* Limit signals and waitpid to this terminal's session, never other windows
     or unrelated application children. The session leader is reaped last. */
  for (attempts = 0; attempts < 100; attempts++) {
    BOOL remaining = NO;
    DIR *directory = opendir("/proc");
    struct dirent *entry;
    if (directory) {
      while ((entry = readdir(directory))) {
        char *end; long number = strtol(entry->d_name, &end, 10);
        if (*end || number <= 0 || number == child) continue;
        pid_t pid = (pid_t)number;
        if (getsid(pid) != child) continue;
        if (attempts == 0) kill(pid, SIGHUP);
        if (attempts >= 50) kill(pid, SIGKILL);
        pid_t result = waitpid(pid, &status, WNOHANG);
        if (result != pid && getsid(pid) == child) remaining = YES;
      }
      closedir(directory);
    }
    if (!remaining) break;
    if (attempts == 50 && getsid(child) == child) kill(child, SIGKILL);
    usleep(20000);
  }
#else
  for (attempts = 0; attempts < 50; attempts++) {
    if (!(foreground > 0 && foreground != child && getsid(foreground) == child)) break;
    usleep(20000);
  }
  if (foreground > 0 && getsid(foreground) == child) kill(-foreground, SIGKILL);
#endif
  /* A shell can itself ignore HUP. waitpid is off the UI thread. */
  for (attempts = 0; attempts < 50; attempts++) {
    pid_t result = waitpid(child, &status, WNOHANG);
    if (result == child || (result < 0 && errno == ECHILD)) break;
    usleep(20000);
  }
  if (attempts == 50) {
    if (getsid(child) == child) { kill(-child, SIGKILL); kill(child, SIGKILL); }
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
  }
  [cleanupCondition lock];
  cleanupCount--; [cleanupCondition broadcast];
  [cleanupCondition unlock];
  [pool drain];
}
#endif

- (void)stop
{
  [_resizeTimer invalidate]; DESTROY(_resizeTimer);
  _showResizeIndicator = NO;
  [_timer invalidate]; DESTROY(_timer);
#ifndef _WIN32
  pid_t foreground = _master >= 0 ? tcgetpgrp(_master) : -1;
  if (_session > 0) {
    if (foreground > 0 && getsid(foreground) == _session) kill(-foreground, SIGHUP);
    if (getsid(_session) == _session) { kill(-_session, SIGHUP); kill(_session, SIGHUP); }
    [cleanupCondition lock]; cleanupCount++; [cleanupCondition unlock];
    [NSThread detachNewThreadSelector:@selector(reapChild:) toTarget:[self class]
      withObject:[NSArray arrayWithObjects:[NSNumber numberWithInt:_session],
        [NSNumber numberWithInt:foreground], nil]];
  }
  if (_master >= 0) close(_master);
#endif
  _session = _child = _master = -1;
  [_pendingInput setLength:0];
}

- (void)poll:(NSTimer *)timer
{
  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  if (now - _lastBlink >= 0.5) {
    _lastBlink = now; _blinkOn = !_blinkOn;
    if ([[self window] isVisible]) [self setNeedsDisplay:YES];
  }
#ifndef _WIN32
  char buffer[8192]; ssize_t count; NSUInteger total = 0;
  BOOL finished = NO;
  while (_master >= 0 && total < 262144) {
    count = read(_master, buffer, sizeof(buffer));
    if (count > 0) { [self consumeData:[NSData dataWithBytes:buffer length:count]]; total += count; }
    else if (count < 0 && errno == EINTR) continue;
    else { if (count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) finished = YES; break; }
  }
  if (!finished && [_pendingInput length]) {
    count = write(_master, [_pendingInput bytes], [_pendingInput length]);
    if (count > 0) [_pendingInput replaceBytesInRange:NSMakeRange(0, count) withBytes:NULL length:0];
    else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) finished = YES;
  }
  int status;
  if (_child > 0) {
    pid_t result = waitpid(_child, &status, WNOHANG);
    if (result == _child || (result < 0 && errno == ECHILD)) {
      _child = -1;
      // Keep draining output until EOF, including output larger than one poll budget.
      if (total == 0) finished = YES;
    }
  }
  if (finished) {
    [self stop]; _ended = YES;
    [self consumeData:[@"\r\n[Shell exited. Press Return to start a new shell.]\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
  }
#endif
}

- (void)restart:(id)sender
{
  if (!_directory) return;
  [self stop];
  NSError *error = nil;
  if (![self startInDirectory:_directory error:&error]) [[NSAlert alertWithError:error] runModal];
}


- (BOOL)cellAtRow:(NSInteger)row column:(int)column cell:(VTermScreenCell *)cell
{
  NSInteger history = _alternateScreen ? 0 : [_history count];
  memset(cell, 0, sizeof(*cell));
  if (row < 0 || column < 0 || column >= _columns) return NO;
  if (row < history) {
    NSData *line = [_history objectAtIndex:row];
    if ((column + 1) * sizeof(*cell) > [line length]) return NO;
    *cell = ((const VTermScreenCell *)[line bytes])[column]; return YES;
  }
  VTermPos position = { (int)(row - history), column };
  return position.row < _rows && vterm_screen_get_cell(_screen, position, cell);
}

- (NSString *)screenText
{
  NSMutableString *text = [NSMutableString string]; int row, col;
  NSInteger history = _alternateScreen ? 0 : [_history count];
  for (row = 0; row < _rows; row++) {
    for (col = 0; col < _columns; col++) {
      VTermScreenCell cell;
      if ([self cellAtRow:history + row column:col cell:&cell] && cell.chars[0] != (uint32_t)-1)
        [text appendString:terminalCellString(&cell)];
    }
    [text appendString:@"\n"];
  }
  return text;
}

- (NSColor *)color:(VTermColor)color
{
  if (VTERM_COLOR_IS_DEFAULT_FG(&color)) return _foregroundColor;
  if (VTERM_COLOR_IS_DEFAULT_BG(&color)) return _backgroundColor;
  vterm_screen_convert_color_to_rgb(_screen, &color);
  return [NSColor colorWithCalibratedRed:color.rgb.red / 255.0 green:color.rgb.green / 255.0
    blue:color.rgb.blue / 255.0 alpha:1];
}

- (void)drawRect:(NSRect)dirty
{
  [_backgroundColor set]; NSRectFill(dirty);
  NSInteger history = _alternateScreen ? 0 : [_history count];
  NSInteger first = history - _scrollOffset;
  NSInteger low = MIN(_selectionStart, _selectionEnd), high = MAX(_selectionStart, _selectionEnd);
  int row, col, pass;
  // Paint backgrounds before glyphs so a wide glyph is not erased by its
  // trailing cell. Clip each glyph to its terminal cell(s), not its font advance.
  for (pass = 0; pass < 2; pass++) for (row = 0; row < _rows; row++) {
    for (col = 0; col < _columns; col++) {
      NSRect rect = NSMakeRect([NSScroller scrollerWidth] + col * _cellWidth, row * _cellHeight, _cellWidth, _cellHeight);
      if (!NSIntersectsRect(rect, dirty)) continue;
      VTermScreenCell cell;
      if (![self cellAtRow:first + row column:col cell:&cell]) continue;
      NSColor *fg = [self color:cell.fg], *bg = [self color:cell.bg];
      if (cell.attrs.reverse) { NSColor *swap = fg; fg = bg; bg = swap; }
      NSInteger position = (first + row) * _columns + col;
      if (low >= 0 && position >= low && position <= high) {
        bg = [NSColor selectedTextBackgroundColor]; fg = [NSColor selectedTextColor];
      }
      if (pass == 0) { [bg set]; NSRectFill(rect); continue; }
      if (cell.chars[0] == (uint32_t)-1 || cell.attrs.conceal || (cell.attrs.blink && !_blinkOn)) continue;
      NSFont *font = cell.attrs.bold ? _boldFont : _font;
      if (cell.attrs.italic) {
        NSFont *italic = [[NSFontManager sharedFontManager] convertFont:font toHaveTrait:NSItalicFontMask];
        if (italic) font = italic;
      }
      NSMutableDictionary *attributes = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        font, NSFontAttributeName, fg, NSForegroundColorAttributeName, nil];
      if (cell.attrs.underline) [attributes setObject:[NSNumber numberWithInt:
        cell.attrs.underline == VTERM_UNDERLINE_DOUBLE ? NSUnderlineStyleDouble : NSUnderlineStyleSingle]
        forKey:NSUnderlineStyleAttributeName];
      if (cell.attrs.strike) [attributes setObject:[NSNumber numberWithInt:NSUnderlineStyleSingle] forKey:NSStrikethroughStyleAttributeName];
      [NSGraphicsContext saveGraphicsState];
      NSRectClip(NSMakeRect(rect.origin.x, rect.origin.y, _cellWidth * MAX(1, cell.width), _cellHeight));
      [[terminalCellString(&cell) precomposedStringWithCanonicalMapping]
        drawAtPoint:rect.origin withAttributes:attributes];
      [NSGraphicsContext restoreGraphicsState];
    }
  }
  BOOL cursorCanBlink = _allowCursorBlink && _cursorBlink && [self isRunning]
    && [NSApp isActive] && [[self window] isKeyWindow] && [[self window] firstResponder] == self;
  if (_cursorVisible && !_scrollOffset && (!cursorCanBlink || _blinkOn)) {
    VTermPos cursor; vterm_state_get_cursorpos(vterm_obtain_state(_terminal), &cursor);
    [_cursorColor set];
    NSInteger shape = _preferredCursorShape;
    if (shape == 0) shape = _cursorShape == VTERM_PROP_CURSORSHAPE_UNDERLINE ? 4
        : (_cursorShape == VTERM_PROP_CURSORSHAPE_BAR_LEFT ? 3 : 1);
    NSRect rect = NSMakeRect([NSScroller scrollerWidth] + cursor.col * _cellWidth, cursor.row * _cellHeight, _cellWidth, _cellHeight);
    if (shape == 4)
      NSRectFill(NSMakeRect(rect.origin.x, NSMaxY(rect) - 2, _cellWidth, 2));
    else if (shape == 3)
      NSRectFill(NSMakeRect(rect.origin.x, rect.origin.y, 2, _cellHeight));
    else if (shape == 1) {
      NSRectFill(rect);
      VTermScreenCell cell;
      if (vterm_screen_get_cell(_screen, cursor, &cell) && cell.chars[0] != (uint32_t)-1 && !cell.attrs.conceal) {
        NSColor *rgb = [_cursorColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
        NSColor *ink = ([rgb redComponent] * 0.299 + [rgb greenComponent] * 0.587 + [rgb blueComponent] * 0.114) > 0.5
          ? [NSColor blackColor] : [NSColor whiteColor];
        [NSGraphicsContext saveGraphicsState]; NSRectClip(rect);
        [terminalCellString(&cell) drawAtPoint:rect.origin withAttributes:
          [NSDictionary dictionaryWithObjectsAndKeys:cell.attrs.bold ? _boldFont : _font, NSFontAttributeName,
            ink, NSForegroundColorAttributeName, nil]];
        [NSGraphicsContext restoreGraphicsState];
      }
    }
    else NSFrameRect(rect);
  }
  if (_showResizeIndicator || [self inLiveResize]) {
    NSString *text = [NSString stringWithFormat:@"%d x %d", _columns, _rows];
    NSDictionary *attributes = [NSDictionary dictionaryWithObjectsAndKeys:
      [NSFont boldSystemFontOfSize:14], NSFontAttributeName,
      [NSColor blackColor], NSForegroundColorAttributeName, nil];
    NSSize size = [text sizeWithAttributes:attributes];
    NSRect box = NSMakeRect(floor(NSMidX([self bounds]) - (size.width + 24) / 2),
      floor(NSMidY([self bounds]) - (size.height + 16) / 2), size.width + 24, size.height + 16);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:box xRadius:6 yRadius:6];
    [[NSColor colorWithCalibratedRed:1 green:1 blue:0.85 alpha:1] set]; [path fill];
    [[NSColor darkGrayColor] set]; [path stroke];
    [text drawAtPoint:NSMakePoint(box.origin.x + 12, box.origin.y + 8) withAttributes:attributes];
  }
}


- (void)keyDown:(NSEvent *)event
{
  NSString *characters = [event characters];
  if (![characters length]) return;
  unichar c = [characters characterAtIndex:0];
  if (_ended && (c == '\r' || c == '\n')) { [self restart:nil]; return; }
  if (!_alternateScreen && ([event modifierFlags] & NSShiftKeyMask)
      && (c == NSPageUpFunctionKey || c == NSPageDownFunctionKey)) {
    _scrollOffset = MIN((NSInteger)[_history count], MAX(0,
      _scrollOffset + (c == NSPageUpFunctionKey ? _rows : -_rows)));
    [self updateScroller];
    [self setNeedsDisplay:YES]; return;
  }
  _scrollOffset = 0; _selectionStart = _selectionEnd = -1;
  _wheelRemainder = 0; [self updateScroller];
  VTermModifier mods = terminalModifiers(event);
  if (c == NSBackTabCharacter) mods |= VTERM_MOD_SHIFT;
  VTermKey key = VTERM_KEY_NONE;
  switch (c) {
    case '\r': case '\n': key = VTERM_KEY_ENTER; break;
    case '\t': case NSBackTabCharacter: key = VTERM_KEY_TAB; break;
    case 0x7f: case '\b': key = VTERM_KEY_BACKSPACE; break;
    case 0x1b: key = VTERM_KEY_ESCAPE; break;
    case NSUpArrowFunctionKey: key = VTERM_KEY_UP; break;
    case NSDownArrowFunctionKey: key = VTERM_KEY_DOWN; break;
    case NSLeftArrowFunctionKey: key = VTERM_KEY_LEFT; break;
    case NSRightArrowFunctionKey: key = VTERM_KEY_RIGHT; break;
    case NSHomeFunctionKey: key = VTERM_KEY_HOME; break;
    case NSEndFunctionKey: key = VTERM_KEY_END; break;
    case NSInsertFunctionKey: key = VTERM_KEY_INS; break;
    case NSDeleteFunctionKey: key = VTERM_KEY_DEL; break;
    case NSPageUpFunctionKey: key = VTERM_KEY_PAGEUP; break;
    case NSPageDownFunctionKey: key = VTERM_KEY_PAGEDOWN; break;
  }
  if (c >= NSF1FunctionKey && c <= NSF35FunctionKey) key = VTERM_KEY_FUNCTION(c - NSF1FunctionKey + 1);
  if ([event modifierFlags] & NSNumericPadKeyMask) {
    if (c >= '0' && c <= '9') key = VTERM_KEY_KP_0 + c - '0';
    else if (c == '\r' || c == '\n' || c == NSEnterCharacter) key = VTERM_KEY_KP_ENTER;
    else if (c == '+') key = VTERM_KEY_KP_PLUS;
    else if (c == '-') key = VTERM_KEY_KP_MINUS;
    else if (c == '*') key = VTERM_KEY_KP_MULT;
    else if (c == '/') key = VTERM_KEY_KP_DIVIDE;
    else if (c == '.') key = VTERM_KEY_KP_PERIOD;
    else if (c == ',') key = VTERM_KEY_KP_COMMA;
    else if (c == '=') key = VTERM_KEY_KP_EQUAL;
  }
  if (key) vterm_keyboard_key(_terminal, key, mods);
  else {
    // charactersIgnoringModifiers preserves the letter for Control/Alt chords.
    if (mods & (VTERM_MOD_CTRL | VTERM_MOD_ALT)) characters = [event charactersIgnoringModifiers];
    NSUInteger i;
    for (i = 0; i < [characters length]; i++) {
      uint32_t code = [characters characterAtIndex:i];
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < [characters length]) {
        unichar tail = [characters characterAtIndex:i + 1];
        if (tail >= 0xdc00 && tail <= 0xdfff) { code = 0x10000 + ((code - 0xd800) << 10) + tail - 0xdc00; i++; }
      }
      vterm_keyboard_unichar(_terminal, code, mods);
    }
  }
  [self setNeedsDisplay:YES];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
  if ([[self window] firstResponder] == self && ([event modifierFlags] & NSControlKeyMask)
      && !([event modifierFlags] & NSCommandKeyMask)) { [self keyDown:event]; return YES; }
  return [super performKeyEquivalent:event];
}

- (NSInteger)positionForEvent:(NSEvent *)event
{
  NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
  NSInteger history = _alternateScreen ? 0 : [_history count];
  int row = MIN(_rows - 1, MAX(0, (int)(p.y / _cellHeight)));
  int col = MIN(_columns - 1, MAX(0, (int)((p.x - [NSScroller scrollerWidth]) / _cellWidth)));
  return (history - _scrollOffset + row) * _columns + col;
}

- (BOOL)reportMouse:(NSEvent *)event button:(int)button pressed:(BOOL)pressed
{
  if (!_mouseReporting || ([event modifierFlags] & NSShiftKeyMask)) return NO;
  NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
  vterm_mouse_move(_terminal, MIN(_rows - 1, MAX(0, (int)(p.y / _cellHeight))),
    MIN(_columns - 1, MAX(0, (int)((p.x - [NSScroller scrollerWidth]) / _cellWidth))), terminalModifiers(event));
  if (button) vterm_mouse_button(_terminal, button, pressed, terminalModifiers(event));
  return YES;
}

- (void)mouseDown:(NSEvent *)event
{
  [[self window] makeFirstResponder:self];
  if ([self reportMouse:event button:1 pressed:YES]) return;
  _selectionStart = _selectionEnd = [self positionForEvent:event]; [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event
{
  if ([self reportMouse:event button:0 pressed:NO]) return;
  _selectionEnd = [self positionForEvent:event]; [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event { [self reportMouse:event button:1 pressed:NO]; }

- (void)rightMouseDown:(NSEvent *)event
{
  if (![self reportMouse:event button:3 pressed:YES]) [super rightMouseDown:event];
}

- (void)rightMouseUp:(NSEvent *)event { [self reportMouse:event button:3 pressed:NO]; }

- (void)rightMouseDragged:(NSEvent *)event { [self reportMouse:event button:0 pressed:NO]; }

- (void)otherMouseDown:(NSEvent *)event { [self reportMouse:event button:2 pressed:YES]; }

- (void)otherMouseUp:(NSEvent *)event { [self reportMouse:event button:2 pressed:NO]; }

- (void)otherMouseDragged:(NSEvent *)event { [self reportMouse:event button:0 pressed:NO]; }

- (void)mouseMoved:(NSEvent *)event { [self reportMouse:event button:0 pressed:NO]; }

- (void)updateScroller
{
  NSInteger history = _alternateScreen ? 0 : [_history count];
  _scrollOffset = MIN(history, MAX(0, _scrollOffset));
  [_historyScroller setFloatValue:history ? 1.0 - (double)_scrollOffset / history : 1.0
    knobProportion:(double)_rows / MAX(1, history + _rows)];
  [_historyScroller setEnabled:history > 0];
}

- (void)scrollHistory:(NSScroller *)sender
{
  NSInteger history = _alternateScreen ? 0 : [_history count];
  switch ([sender hitPart]) {
    case NSScrollerDecrementLine: _scrollOffset++; break;
    case NSScrollerIncrementLine: _scrollOffset--; break;
    case NSScrollerDecrementPage: _scrollOffset += MAX(1, _rows - 1); break;
    case NSScrollerIncrementPage: _scrollOffset -= MAX(1, _rows - 1); break;
    default: _scrollOffset = lround((1.0 - [sender doubleValue]) * history); break;
  }
  _wheelRemainder = 0;
  [self updateScroller];
  [self setNeedsDisplay:YES];
}

- (void)scrollWheel:(NSEvent *)event
{
  if ([event deltaY] == 0) return;
  if ([self reportMouse:event button:[event deltaY] > 0 ? 4 : 5 pressed:YES]) return;
  if (_alternateScreen) return;
  // Preserve fractional trackpad movement instead of truncating every event.
  _wheelRemainder += [event deltaY] * 3;
  NSInteger lines = (NSInteger)_wheelRemainder;
  _wheelRemainder -= lines;
  _scrollOffset += lines;
  [self updateScroller];
  [self setNeedsDisplay:YES];
}

- (void)selectAll:(id)sender
{
  _selectionStart = 0;
  _selectionEnd = ((_alternateScreen ? 0 : [_history count]) + _rows) * _columns - 1;
  [self setNeedsDisplay:YES];
}

- (NSPasteboard *)pasteboard { return [NSPasteboard generalPasteboard]; }

- (void)copy:(id)sender
{
  if (_selectionStart < 0) return;
  NSInteger start = MIN(_selectionStart, _selectionEnd), end = MAX(_selectionStart, _selectionEnd);
  NSMutableString *result = [NSMutableString string], *line = [NSMutableString string];
  NSInteger i;
  for (i = start; i <= end; i++) {
    VTermScreenCell cell;
    if ([self cellAtRow:i / _columns column:i % _columns cell:&cell] && cell.chars[0] != (uint32_t)-1)
      [line appendString:terminalCellString(&cell)];
    if (i % _columns == _columns - 1 || i == end) {
      while ([line hasSuffix:@" "]) [line deleteCharactersInRange:NSMakeRange([line length] - 1, 1)];
      [result appendString:line]; [line setString:@""];
      if (i != end) [result appendString:@"\n"];
    }
  }
  NSPasteboard *pasteboard = [self pasteboard];
  [pasteboard declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
  [pasteboard setString:result forType:NSStringPboardType];
}

- (void)paste:(id)sender
{
  NSString *text = [[self pasteboard] stringForType:NSStringPboardType];
  if (![text length]) return;
  // Strip escape bytes so pasted text cannot terminate bracketed-paste mode.
  text = [text stringByReplacingOccurrencesOfString:@"\033" withString:@""];
  text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
  text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@"\r"];
  vterm_keyboard_start_paste(_terminal);
  [self sendData:[text dataUsingEncoding:NSUTF8StringEncoding]];
  vterm_keyboard_end_paste(_terminal);
  _scrollOffset = 0; _wheelRemainder = 0; [self updateScroller]; [self setNeedsDisplay:YES];
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
  NSMenu *menu = AUTORELEASE([[NSMenu alloc] initWithTitle:@"Terminal"]);
  NSArray *titles = [NSArray arrayWithObjects:@"Copy", @"Paste", @"Select All", @"Restart Terminal", nil];
  SEL actions[] = { @selector(copy:), @selector(paste:), @selector(selectAll:), @selector(restart:) };
  NSUInteger i;
  for (i = 0; i < [titles count]; i++) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[titles objectAtIndex:i] action:actions[i] keyEquivalent:@""];
    [item setTarget:self]; [menu addItem:item]; RELEASE(item);
  }
  return menu;
}
@end
