#!/bin/sh
# Compile the actual view, including Objective-C method metadata, without a GUI.
set -eu
cd "$(dirname "$0")/.."
compiler=${CC:-gcc}
PKG_CONFIG=${PKG_CONFIG:-pkg-config}
case ${USE_SYSTEM_LIBVTERM:-no} in
  no) vterm_flags=-ITerminal/libvterm/include ;;
  yes)
    "$PKG_CONFIG" --atleast-version=0.3.3 vterm
    vterm_flags=$("$PKG_CONFIG" --cflags vterm) ;;
  *) echo 'USE_SYSTEM_LIBVTERM must be yes or no' >&2; exit 1 ;;
esac
work=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$work"' EXIT HUP INT TERM
# GNUstep flags are deliberately split into arguments. OBJCFLAGS can supply
# runtime headers for Clang installations that do not locate GCC's objc headers.
# Existing PTY error-path write warnings are outside this regression's scope.
"$compiler" $(gnustep-config --objc-flags) ${OBJCFLAGS:-} $vterm_flags \
  -Werror -Wno-error=unused-result -c TerminalView.m -o "$work/TerminalView.o"
echo "PASS: TerminalView method declarations and type encodings ($compiler, ${USE_SYSTEM_LIBVTERM:-no})"
