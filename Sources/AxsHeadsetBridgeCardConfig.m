#import "AxsHeadsetBridgeCardConfig.h"
#import "AxsHeadsetBridgeCardPreferences.h"
#import "AxsHeadsetCardTimerRuntime.h"
#import <notify.h>

// One 64-bit value contains valid/enabled/integer-seconds, avoiding torn reads.
// SpringBoard is the only publisher. Not authenticated IPC; no music lease data.
static const char *AxsHeadsetBridgeCardStateName="com.axs.headsetbridge.card.runtime-state";
static int AxsHeadsetBridgeCardStateToken=-1;
static BOOL AxsHeadsetBridgeCardPublisher;
static BOOL AxsHeadsetBridgeCardEnabled=YES;
static NSTimeInterval AxsHeadsetBridgeCardSeconds=5.0;
static BOOL AxsHeadsetBridgeCardHasSnapshot;

// nil means read/schema failure; an empty dictionary means confirmed absent.
static NSDictionary *axs_headsetbridge_card_runtimeFile(void) {
    NSError *error=nil;
    NSData *data=[NSData dataWithContentsOfFile:axs_headsetbridge_card_preferencesPath() options:0 error:&error];
    if (!data) {
        if ([error.domain isEqual:NSCocoaErrorDomain] && error.code==NSFileReadNoSuchFileError)return @{};
        return nil;
    }
    if (data.length>65536)return nil;
    id d=[NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:&error];
    if (![d isKindOfClass:[NSDictionary class]])return nil;
    if ((d[@"cardEnabled"] && ![d[@"cardEnabled"] isKindOfClass:[NSNumber class]]) || (d[@"cardSeconds"] && (![d[@"cardSeconds"] isKindOfClass:[NSNumber class]] || !isfinite([d[@"cardSeconds"] doubleValue]))))return nil;
    return d;
}
static void axs_headsetbridge_card_reload(void) {
    if (![NSThread isMainThread])return;
    BOOL enabled=YES;NSInteger seconds=5;NSString *source=@"default";
    BOOL trusted=YES;
    if (AxsHeadsetBridgeCardPublisher) {
        NSDictionary *d=axs_headsetbridge_card_runtimeFile();
        if (!d) {
            // Do not turn an existing OFF into default ON on a read failure.
            // Never publish a valid default after an unknown first read.
            static NSUInteger retries;
            if (retries++<3)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(NSEC_PER_SEC)),dispatch_get_main_queue(),^{axs_headsetbridge_card_reload();});
            if (AxsHeadsetBridgeCardStateToken>=0 && !AxsHeadsetBridgeCardHasSnapshot) {
                if (notify_set_state(AxsHeadsetBridgeCardStateToken,0)==NOTIFY_STATUS_OK)notify_post(AxsHeadsetBridgeCardStateName);
            }
            return;
        }
        if ([d[@"cardEnabled"] isKindOfClass:[NSNumber class]])enabled=[d[@"cardEnabled"] boolValue];
        seconds=axs_headsetbridge_card_seconds(d[@"cardSeconds"]);
        uint64_t state=0x10000ULL | (enabled ? 0x100ULL : 0) | (uint64_t)seconds;
        if (AxsHeadsetBridgeCardStateToken>=0) {
            if (notify_set_state(AxsHeadsetBridgeCardStateToken,state)==NOTIFY_STATUS_OK)notify_post(AxsHeadsetBridgeCardStateName);
        }
        source=@"springboard_file";
    } else {
        // Canonical reads happen on startup/settings notifications only, never
        // in view hooks. Sandbox denial falls back to the SpringBoard relay.
        NSDictionary *d=axs_headsetbridge_card_runtimeFile();
        if (d.count) {
            enabled=d[@"cardEnabled"] ? [d[@"cardEnabled"] boolValue] : YES;seconds=axs_headsetbridge_card_seconds(d[@"cardSeconds"]);source=@"canonical_file";
        } else {
            uint64_t state=0;
            if (AxsHeadsetBridgeCardStateToken>=0 && notify_get_state(AxsHeadsetBridgeCardStateToken,&state)==NOTIFY_STATUS_OK && (state & 0x10000ULL) && !(state & ~0x101ffULL) && (state & 0xff)>=3 && (state & 0xff)<=50) {
                enabled=(state & 0x100)!=0;seconds=(NSInteger)(state & 0xff);source=@"springboard_relay";
            } else {
                trusted=NO;
                if (AxsHeadsetBridgeCardHasSnapshot) {
                    enabled=AxsHeadsetBridgeCardEnabled;seconds=(NSInteger)AxsHeadsetBridgeCardSeconds;source=@"cached_after_read_failure";
                } else if (d) {
                    // Confirmed absent settings retain the standalone ON/5s baseline.
                    enabled=YES;seconds=5;source=@"confirmed_absent_default";trusted=YES;
                } else {
                    // Unknown first read: do not override a potentially saved OFF.
                    enabled=NO;seconds=5;source=@"unavailable_pending_relay";
                }
            }
        }
    }
    if (trusted)AxsHeadsetBridgeCardHasSnapshot=YES;
    AxsHeadsetBridgeCardEnabled=enabled;AxsHeadsetBridgeCardSeconds=seconds;
    if (!AxsHeadsetBridgeCardPublisher) {
        axs_headsetcardtimer_log(@"merged_card_config",@{@"enabled":@(enabled),@"seconds":@(seconds),@"source":source});
        [[NSNotificationCenter defaultCenter] postNotificationName:AxsHeadsetBridgeCardLocalChanged object:nil];
    }
}
static void axs_headsetbridge_card_changed(CFNotificationCenterRef center,void *observer,CFStringRef name,const void *object,CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(),^{axs_headsetbridge_card_reload();});
}
void axs_headsetbridge_card_configStart(void) {
    if (![NSThread isMainThread])return;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        AxsHeadsetBridgeCardPublisher=[[[NSBundle mainBundle] bundleIdentifier] isEqual:@"com.apple.springboard"];
        if (notify_register_check(AxsHeadsetBridgeCardStateName,&AxsHeadsetBridgeCardStateToken)!=NOTIFY_STATUS_OK)AxsHeadsetBridgeCardStateToken=-1;
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,axs_headsetbridge_card_changed,(__bridge CFStringRef)AxsHeadsetBridgeCardChanged,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
        if (!AxsHeadsetBridgeCardPublisher)CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,axs_headsetbridge_card_changed,CFSTR("com.axs.headsetbridge.card.runtime-state"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
        axs_headsetbridge_card_reload();
    });
}
BOOL axs_headsetbridge_card_enabled(void) { return AxsHeadsetBridgeCardEnabled; }
NSTimeInterval axs_headsetbridge_card_delay(void) { return AxsHeadsetBridgeCardSeconds; }
