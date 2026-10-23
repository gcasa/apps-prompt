ifeq ($(GNUSTEP_MAKEFILES),)
GNUSTEP_MAKEFILES := $(shell gnustep-config --variable=GNUSTEP_MAKEFILES)
endif
include $(GNUSTEP_MAKEFILES)/common.make
TOOL_NAME = TerminalTests
TerminalTests_OBJC_FILES = main.m ../TerminalView.m ../TerminalPreferences.m ../AppController.m
VTERM_ROOT = ..
include ../vterm.make
TerminalTests_C_FILES = $(VTERM_C_FILES)
TerminalTests_INCLUDE_DIRS = -I.. $(VTERM_INCLUDE_DIRS)
TerminalTests_TOOL_LIBS += $(VTERM_LIBS)
TerminalTests_CFLAGS = -std=c99
# X11 supplies mouse state while the window manager owns the resize drag.
ifneq ($(shell pkg-config --exists x11 && echo yes),)
TerminalTests_OBJCFLAGS += -DTERMINAL_X11_RESIZE $(shell pkg-config --cflags x11)
TerminalTests_TOOL_LIBS += $(shell pkg-config --libs x11)
endif
TerminalTests_TOOL_LIBS += -lgnustep-gui
include $(GNUSTEP_MAKEFILES)/tool.make
check:: all
	./obj/TerminalTests
