ifeq ($(GNUSTEP_MAKEFILES),)
GNUSTEP_MAKEFILES := $(shell gnustep-config --variable=GNUSTEP_MAKEFILES)
endif
include $(GNUSTEP_MAKEFILES)/common.make
TOOL_NAME = TerminalTests
TerminalTests_OBJC_FILES = main.m ../TerminalView.m ../TerminalPreferences.m ../AppController.m
TerminalTests_C_FILES = $(wildcard ../Terminal/libvterm/src/*.c)
TerminalTests_INCLUDE_DIRS = -I.. -I../Terminal/libvterm/include
TerminalTests_CFLAGS = -std=c99
TerminalTests_TOOL_LIBS = -lgnustep-gui
include $(GNUSTEP_MAKEFILES)/tool.make
check:: all
	./obj/TerminalTests
