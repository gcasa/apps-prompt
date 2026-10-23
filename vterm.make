# Shared by the application and regression tests. VTERM_ROOT is relative to
# the including makefile. Never mix system headers with bundled objects.
USE_SYSTEM_LIBVTERM ?= no
PKG_CONFIG ?= pkg-config
ifeq ($(USE_SYSTEM_LIBVTERM),yes)
ifeq ($(shell $(PKG_CONFIG) --atleast-version=0.3.3 vterm && echo yes),)
$(error USE_SYSTEM_LIBVTERM=yes requires libvterm >= 0.3.3 and its vterm.pc file)
endif
VTERM_C_FILES =
VTERM_INCLUDE_DIRS = $(shell $(PKG_CONFIG) --cflags vterm)
VTERM_LIBS = $(shell $(PKG_CONFIG) --libs vterm)
else ifeq ($(USE_SYSTEM_LIBVTERM),no)
VTERM_C_FILES = $(wildcard $(VTERM_ROOT)/Terminal/libvterm/src/*.c)
VTERM_INCLUDE_DIRS = -I$(VTERM_ROOT)/Terminal/libvterm/include
VTERM_LIBS =
else
$(error USE_SYSTEM_LIBVTERM must be yes or no)
endif
