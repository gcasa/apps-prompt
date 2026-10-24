ifeq ($(GNUSTEP_MAKEFILES),)
GNUSTEP_MAKEFILES := $(shell gnustep-config --variable=GNUSTEP_MAKEFILES)
endif
include $(GNUSTEP_MAKEFILES)/common.make
TOOL_NAME = TerminalTests
TerminalTests_OBJC_FILES = main.m ../TerminalView.m ../TerminalPreferences.m ../AppController.m ../Terminal/TerminalParser_VT100.m
TerminalTests_INCLUDE_DIRS = -I..
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
