TARGET := iphone:clang:latest:14.0
ARCHS := arm64

INSTALL_TARGET_PROCESSES = WeChat

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WeChatMomentsHQ
WeChatMomentsHQ_FILES = Tweak.xm WCMHQManager.m WCMHQDebugPanel.m
WeChatMomentsHQ_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
WeChatMomentsHQ_FRAMEWORKS = UIKit Foundation AVFoundation Photos CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk
