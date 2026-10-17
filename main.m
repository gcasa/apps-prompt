/* Standalone GNUstep Terminal. GPL-2.0-or-later; see COPYING. */
#import "AppController.h"
int main(int argc, const char **argv)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  [NSApplication sharedApplication];
  AppController *controller = [AppController new];
  [NSApp setDelegate:controller];
  [NSApp run];
  [NSApp setDelegate:nil]; [controller release]; [pool drain];
  return 0;
}
