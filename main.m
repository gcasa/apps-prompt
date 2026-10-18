/* Standalone GNUstep Prompt. GPL-2.0-or-later; see COPYING. */
#import "AppController.h"
int main(int argc, const char **argv)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  // GNUstep migrates defaults from the process name to the bundle identifier.
  // Use our own name before defaults initialize so a legacy Terminal domain
  // belonging to another terminal application is never adopted or moved.
  [[NSProcessInfo processInfo] setProcessName:@"io.github.gcasa.apps-terminal"];
  [NSApplication sharedApplication];
  AppController *controller = [AppController new];
  [NSApp setDelegate:controller];
  [NSApp run];
  [NSApp setDelegate:nil]; [controller release]; [pool drain];
  return 0;
}
