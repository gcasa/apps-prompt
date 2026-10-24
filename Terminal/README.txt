Terminal emulation engine

TerminalParser_VT100 is adapted from the application-owned Objective-C engine
in the sibling apps-terminal project (GNUstep Terminal), under GPL version 3
or later (see COPYING.engine). Its copyright and license notices are preserved in the sources.
The emulation engine was inspired by libvterm, by Paul Evans and contributors.
No libvterm source, headers, library, or runtime dependency is included.

Prompt uses native TerminalGlyph cells and a TerminalScreen delegate for
scrollback, output, invalidation, and cursor state. Prompt-specific integration
adds mouse and focus reporting, cursor style selection, and double underline,
and uses Prompt's existing keyboard modifier and bell preferences.

The engine builds with the application; no downloads or generators are needed.
