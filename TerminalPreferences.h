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

#import <AppKit/AppKit.h>
extern NSString *TerminalPreferencesDidChangeNotification;
@interface TerminalPreferences : NSObject
+ (BOOL)isTerminalFont:(NSFont *)font;
+ (NSFont *)terminalFont;

+ (void)setTerminalFont:(NSFont *)font;
+ (NSColor *)terminalForegroundColor;
+ (NSColor *)terminalBackgroundColor;
+ (void)setTerminalForegroundColor:(NSColor *)foreground backgroundColor:(NSColor *)background;
+ (NSColor *)terminalCursorColor;
+ (void)setTerminalCursorColor:(NSColor *)color;
/** Cursor shape: 0 program controlled, 1 block, 2 outline, 3 line, 4 underline. */
+ (NSInteger)terminalCursorShape;
+ (void)setTerminalCursorShape:(NSInteger)shape;
+ (NSUInteger)terminalScrollbackLines;
+ (void)setTerminalScrollbackLines:(NSUInteger)lines;
+ (BOOL)terminalAudibleBell;
+ (void)setTerminalAudibleBell:(BOOL)enabled;
+ (BOOL)terminalCursorBlink;
+ (void)setTerminalCursorBlink:(BOOL)enabled;
+ (void)resetTerminalPreferences;
@end
