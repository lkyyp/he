THEOS_PACKAGE_SCHEME ?= rootless
DEBUG ?= 0
FINALPACKAGE ?= 1

# Share the SDK and deployment targets with the PreferenceBundle.
include AxsHeadsetBridgeBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AxsHeadsetBridge AxsHeadsetBridgeCard
AxsHeadsetBridge_FILES = \
    Hooks/AxsHeadsetBridgeMain.xm \
    Sources/AxsHeadsetBridgeConfig.m \
    Sources/AxsHeadsetBridgeGate.m \
    Sources/AxsHeadsetBridgeCloudConfig.m \
    Sources/AxsHeadsetBridgeCloudLog.m \
    Sources/AxsHeadsetBridgeCloudMusic.m \
    Sources/AxsHeadsetBridgeCloudPlayback.m \
    Sources/AxsHeadsetBridgeCloudSpringBoard.m \
    Sources/AxsHeadsetBridgeKuwoConfig.m \
    Sources/AxsHeadsetBridgeKuwoLog.m \
    Sources/AxsHeadsetBridgeKuwoMusic.m \
    Sources/AxsHeadsetBridgeKuwoPlayback.m \
    Sources/AxsHeadsetBridgeKuwoSpringBoard.m \
    Sources/AxsHeadsetBridgeKuwoBackground.m \
    Sources/AxsHeadsetBridgeKuwoProcess.m \
    Sources/AxsHeadsetBridgeKuwoDiagnostics.m \
    Sources/AxsHeadsetBridgeKuwoFlowTrace.m \
    Sources/AxsHeadsetBridgeAudioStatus.m
AxsHeadsetBridge_CFLAGS = -fobjc-arc -I./Sources
AxsHeadsetBridge_FRAMEWORKS = UIKit Foundation CoreFoundation AVFoundation MediaPlayer AudioToolbox
AxsHeadsetBridge_LIBRARIES = substrate

# Card code is a separate target and never loads into either music app.
AxsHeadsetBridgeCard_FILES = \
    Hooks/AxsHeadsetBridgeCardMain.xm \
    Sources/AxsHeadsetBridgeCardConfig.m \
    Sources/AxsHeadsetCardTimerController.m \
    Sources/AxsHeadsetCardTimerLog.m
AxsHeadsetBridgeCard_CFLAGS = -fobjc-arc -I./Sources
AxsHeadsetBridgeCard_FRAMEWORKS = UIKit Foundation CoreFoundation
AxsHeadsetBridgeCard_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += AxsHeadsetBridgePrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
