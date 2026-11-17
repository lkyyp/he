#import "AxsHeadsetBridgeConfig.h"
#import "AxsHeadsetBridgePreferences.h"
#import "AxsHeadsetBridgeGate.h"

@interface AxsHeadsetBridgeConfig ()
@property (atomic, copy) NSDictionary *snapshot;
@property (nonatomic, strong) dispatch_queue_t reloadQueue;
@end

static void axs_headsetbridge_preferencesDidChange(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef info) {
    AxsHeadsetBridgeConfig *config = (__bridge AxsHeadsetBridgeConfig *)observer;
    axs_headsetbridge_engineLog(@"control",@"config.preferences_notification_received",@{});
    dispatch_async(config.reloadQueue, ^{
        [config axs_headsetbridge_reload];
    });
}

@implementation AxsHeadsetBridgeConfig

+ (instancetype)axs_headsetbridge_shared {
    static AxsHeadsetBridgeConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _reloadQueue = dispatch_queue_create("com.axs.headsetbridge.preferences", DISPATCH_QUEUE_SERIAL);
        [self axs_headsetbridge_reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, axs_headsetbridge_preferencesDidChange,
            (__bridge CFStringRef)AxsHeadsetBridgePreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // Close the window between the first read and observer registration.
        dispatch_async(_reloadQueue, ^{ [self axs_headsetbridge_reload]; });
    }
    return self;
}

- (void)axs_headsetbridge_reload {
    self.snapshot = axs_headsetbridge_readPreferences();
    dispatch_async(dispatch_get_main_queue(), ^{
        axs_headsetbridge_engineLog(@"control",@"config.local_reload_delivered",@{});
        [[NSNotificationCenter defaultCenter] postNotificationName:AxsHeadsetBridgePreferencesChanged object:self];
    });
}

- (id)axs_headsetbridge_valueForKey:(NSString *)key defaultValue:(id)defaultValue {
    return self.snapshot[key] ?: defaultValue;
}

- (BOOL)axs_headsetbridge_isEnabled {
    id value = [self axs_headsetbridge_valueForKey:@"enabled" defaultValue:@(NO)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
