ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NetSpeedStatus

NetSpeedStatus_FILES = Tweak.xm
NetSpeedStatus_FRAMEWORKS = UIKit
NetSpeedStatus_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
