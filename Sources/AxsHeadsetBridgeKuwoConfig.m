#import "AxsHeadsetBridgeKuwoConfig.h"
#import "AxsHeadsetBridgeGate.h"
@implementation AxsHeadsetBridgeKuwoConfig
+ (instancetype)axs_headsetbridge_kuwo_shared {
    static AxsHeadsetBridgeKuwoConfig *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [self new]; });
    return instance;
}
- (BOOL)axs_headsetbridge_kuwo_isEnabled { return axs_headsetbridge_enabledFor(@"kuwo"); }
@end
