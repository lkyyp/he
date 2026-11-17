include ../AxsHeadsetBridgeBuild.mk
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AxsHeadsetBridgePrefs
AxsHeadsetBridgePrefs_FILES = $(wildcard *.m)
AxsHeadsetBridgePrefs_CFLAGS = -fobjc-arc -I../Sources
AxsHeadsetBridgePrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
AxsHeadsetBridgePrefs_PRIVATE_FRAMEWORKS = Preferences
AxsHeadsetBridgePrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
