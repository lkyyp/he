#import "AxsHeadsetBridgeCloudConfig.h"
#import "AxsHeadsetBridgeGate.h"
@implementation AxsHeadsetBridgeCloudConfig
+ (instancetype)axs_headsetbridge_cloud_shared {
    static AxsHeadsetBridgeCloudConfig *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [self new]; });
    return instance;
}
- (BOOL)axs_headsetbridge_cloud_isEnabled { return axs_headsetbridge_enabledFor(@"cloud"); }
@end
