#import <Foundation/Foundation.h>
#import "AxsHeadsetBridgeCardConfig.h"
#import "AxsHeadsetCardTimerRuntime.h"

%ctor {
    @autoreleasepool {
        NSString *bundle=[NSBundle mainBundle].bundleIdentifier;
        BOOL service=[[NSProcessInfo processInfo].processName isEqual:@"SharingViewService"];
        if (!service && ![bundle isEqual:@"com.apple.springboard"])return;
        dispatch_async(dispatch_get_main_queue(),^{
            axs_headsetbridge_card_configStart();
            if (!service)return; // SpringBoard only relays card settings.
            [[NSNotificationCenter defaultCenter] addObserverForName:AxsHeadsetBridgeCardLocalChanged object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note){
                axs_headsetcardtimer_configChanged();
            }];
            axs_headsetcardtimer_start();
            for (NSNumber *second in @[@1,@3]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(second.doubleValue*NSEC_PER_SEC)),dispatch_get_main_queue(),^{axs_headsetcardtimer_start();});
            }
        });
    }
}
