ifeq ($(GNUSTEP_MAKEFILES),)
GNUSTEP_MAKEFILES := $(shell gnustep-config --variable=GNUSTEP_MAKEFILES)
endif
include $(GNUSTEP_MAKEFILES)/common.make
APP_NAME = Terminal
VERSION = 1.0
Terminal_OBJC_FILES = main.m AppController.m TerminalView.m TerminalPreferences.m
Terminal_C_FILES = $(wildcard Terminal/libvterm/src/*.c)
Terminal_INCLUDE_DIRS = -ITerminal/libvterm/include
Terminal_CFLAGS = -std=c99
Terminal_APPLICATION_ICON = Terminal.png
Terminal_RESOURCE_FILES = Resources/Terminal.png Resources/Help.txt Resources/libvterm-LICENSE.txt COPYING
include $(GNUSTEP_MAKEFILES)/application.make
check:: all
	$(MAKE) -C Tests check
