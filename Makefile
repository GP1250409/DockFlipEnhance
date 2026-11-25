THEOS_PACKAGE_SCHEME ?= roothide

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
ARCHS = arm64e
else
ARCHS = arm64 arm64e
endif

TARGET := iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DockFlipEnhance

DockFlipEnhance_FILES = Tweak.m
DockFlipEnhance_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
DockFlipEnhance_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
