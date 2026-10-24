/*
 * This file is part of Terminal.app.
 * Copyright (C) 2026 Terminal contributors.
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License, version 3 or later.
 * This program is distributed WITHOUT ANY WARRANTY; without even the implied
 * warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See <https://www.gnu.org/licenses/> for a copy of the license.
 */

#import "Terminal.h"
#import <AppKit/NSEvent.h>
#import <Foundation/Foundation.h>

/* UTF-8 VT100/ANSI terminal with the xterm extensions used by text programs.
   All state belongs to this instance; the screen is a non-owning delegate. */
@interface TerminalParser_VT100 : NSObject <TerminalParser>
{
  id<TerminalScreen> ts;
  int width, height, x, y, top, bottom, left, right;
  screen_char_t *primaryCells, *alternateCells, *cells;
  unsigned char *tabs, *dirtyRows;
  BOOL alternate, wrapPending, autoWrap, originMode, insertMode, newlineMode;
  BOOL cursorVisible, applicationCursor, applicationKeypad, bracketedPaste;
  BOOL leftRightMode, screenReverse;
  int savedX[2], savedY[2];
  BOOL savedWrap[2], savedOrigin[2];
  unsigned char savedCharset[2][4], savedShift[2];
  TerminalGlyph pen, savedPen[2];
  TerminalColor palette[256];
  unsigned char charset[4], shift, singleShift;
  uint32_t lastCharacter, utfValue, utfMinimum;
  int utfRemaining;
  int mouseMode, mouseEncoding, mouseButtons, mouseRow, mouseColumn;
  BOOL focusReporting;
  int parseState, stringState, charsetSlot;
  char leader, intermediate;
  int parameters[32], parameterCount;
  BOOL colonParameter[32], invalidSequence, stringOverflow;
  NSMutableData *controlString;
}

- (void)reset:(BOOL)hard;
- (void)flush;
- (BOOL)getCell:(TerminalGlyph *)cell row:(int)row column:(int)column;
- (TerminalPosition)cursorPosition;
- (TerminalColor)resolvedColor:(TerminalColor)color;
- (void)focusChanged:(BOOL)focused;
- (void)mouseRow:(int)row
          column:(int)column
          button:(int)button
         pressed:(BOOL)pressed
       modifiers:(NSUInteger)flags;

@end
