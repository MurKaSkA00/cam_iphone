THEOS_PACKAGE_SCHEME = rootless
TARGET = iphone:clang:latest:14.0
ARCHS = arm64
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MediaPlaybackUtils
MediaPlaybackUtils_FILES = Tweak.x JailbreakBypass.x StealthHooks.x AntifraudHooks.x \
                           MediaBufferAdapter.m FrameProcessor.m
MediaPlaybackUtils_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable
MediaPlaybackUtils_FRAMEWORKS = UIKit AVFoundation CoreMedia CoreVideo QuartzCore \
                                CoreGraphics CoreImage Foundation ImageIO IOSurface \
                                MobileCoreServices VideoToolbox

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
