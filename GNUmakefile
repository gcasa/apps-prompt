ifeq ($(GNUSTEP_MAKEFILES),)
GNUSTEP_MAKEFILES := $(shell gnustep-config --variable=GNUSTEP_MAKEFILES)
endif
include $(GNUSTEP_MAKEFILES)/common.make
APP_NAME = Prompt
VERSION = 1.0
Prompt_OBJC_FILES = main.m AppController.m TerminalView.m TerminalPreferences.m Terminal/TerminalParser_VT100.m
Prompt_CFLAGS = -std=c99
# X11 supplies mouse state while the window manager owns the resize drag.
ifneq ($(shell pkg-config --exists x11 && echo yes),)
Prompt_OBJCFLAGS += -DTERMINAL_X11_RESIZE $(shell pkg-config --cflags x11)
Prompt_GUI_LIBS += $(shell pkg-config --libs x11)
endif
Prompt_APPLICATION_ICON = Terminal.png
Prompt_RESOURCE_FILES = Resources/Terminal.png Resources/Help.txt COPYING COPYING.engine
include $(GNUSTEP_MAKEFILES)/application.make
check:: all
	$(MAKE) -C Tests check
