# GNUstep Terminal

Independent, manual-reference-counted AppKit terminal using bundled libvterm
0.3.3 and asynchronous, nonblocking POSIX PTY I/O. No Ycode libraries required.
New windows open at 80 columns by 25 rows, with the history scroller on the left.

Build with the configured GNUstep development environment:

```sh
make
./Terminal.app/Terminal
./Terminal.app/Terminal --directory /tmp
make check
```

Dependencies: GNUstep Make, Base and GUI, an Objective-C compiler, a GUI backend,
and POSIX UNIX 98 PTYs. libvterm is included; no network downloads are needed.
`make install` uses the standard GNUstep application target (optional).
Tests require a display; use `xvfb-run -a make check` for an isolated display.

See [bundled offline Help](Resources/Help.txt) for usage, lifecycle, preferences,
and compatibility limits. Help is also available from the application menu.

TerminalView and preference storage were adapted from Ycode under GPL-2.0-or-later.
Original copyright/author notices are retained. The standalone app has its own
classes, defaults domain and controller. See [COPYING](COPYING) and the unmodified
[libvterm MIT license](Terminal/libvterm/LICENSE). Vendored engine provenance:
[Terminal/README.txt](Terminal/README.txt).
