#import "AxsHeadsetBridgeKuwoRuntime.h"
#import "AxsHeadsetBridgeKuwoConfig.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <notify.h>

@interface AxsHeadsetBridgeKuwoBackgroundAttempt : NSObject
@property (nonatomic) UIBackgroundTaskIdentifier identifier;
@property (nonatomic) uint64_t lease;
@property (nonatomic) BOOL finished;
@property (nonatomic) BOOL preparationHold;
@property (nonatomic) NSTimeInterval preparationDeadline;
@end
@implementation AxsHeadsetBridgeKuwoBackgroundAttempt
@end

static AxsHeadsetBridgeKuwoBackgroundAttempt *AxsHeadsetBridgeKuwoBackgroundActive;
static uint32_t AxsHeadsetBridgeKuwoBackgroundLastSession;
static int AxsHeadsetBridgeKuwoBackgroundLeaseToken = -1;
static int AxsHeadsetBridgeKuwoBackgroundConsumedToken = -1;
static BOOL AxsHeadsetBridgeKuwoBackgroundReady;
static int AxsHeadsetBridgeKuwoBackgroundAttemptedToken = -1;

static void axs_headsetbridge_kuwo_backgroundEndInternal(AxsHeadsetBridgeKuwoBackgroundAttempt *attempt, NSString *reason) {
    NSCAssert([NSThread isMainThread], @"Background task lifecycle must run on main");
    if (!attempt || attempt.finished) return;
    attempt.finished = YES;
    UIBackgroundTaskIdentifier identifier = attempt.identifier;
    attempt.identifier = UIBackgroundTaskInvalid;
    if (AxsHeadsetBridgeKuwoBackgroundActive == attempt) AxsHeadsetBridgeKuwoBackgroundActive = nil;
    if (identifier != UIBackgroundTaskInvalid) [[UIApplication sharedApplication] endBackgroundTask:identifier];
    axs_headsetbridge_kuwo_log(@"kuwo.background_task_end", @{@"session": @((uint32_t)(attempt.lease >> 32)), @"reason": reason, @"had_identifier": @(identifier != UIBackgroundTaskInvalid), @"uptime_at_end": @([NSProcessInfo processInfo].systemUptime)});
}

static void axs_headsetbridge_kuwo_backgroundEnd(AxsHeadsetBridgeKuwoBackgroundAttempt *attempt, NSString *reason) {
    @try { axs_headsetbridge_kuwo_backgroundEndInternal(attempt, reason); }
    @catch (NSException *e) { (void)e; }
}

static BOOL axs_headsetbridge_kuwo_backgroundRoute(void) {
    for (AVAudioSessionPortDescription *port in [AVAudioSession sharedInstance].currentRoute.outputs) {
        if ([port.portType isEqual:AVAudioSessionPortBluetoothA2DP] || [port.portType isEqual:AVAudioSessionPortBluetoothLE]) return YES;
    }
    return NO;
}

static uint64_t axs_headsetbridge_kuwo_backgroundLease(void) {
    if (!AxsHeadsetBridgeKuwoBackgroundReady || ![[AxsHeadsetBridgeKuwoConfig axs_headsetbridge_kuwo_shared] axs_headsetbridge_kuwo_isEnabled]) return 0;
    NSBundle *bundle = [NSBundle mainBundle];
    if (![bundle.bundleIdentifier isEqual:@"com.yeelion.kwplayer"] || ![[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:@"12.0.0"] || ![[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:@"11418"]) return 0;
    uint64_t lease = 0, consumed = 0;
    if (notify_get_state(AxsHeadsetBridgeKuwoBackgroundLeaseToken, &lease) != NOTIFY_STATUS_OK || notify_get_state(AxsHeadsetBridgeKuwoBackgroundConsumedToken, &consumed) != NOTIFY_STATUS_OK) return 0;
    if (!axs_headsetbridge_bindingValid(@"kuwo", lease)) return 0;
    uint32_t session = (uint32_t)(lease >> 32);
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    NSTimeInterval expiry = (uint32_t)lease;
    AxsHeadsetBridgeKuwoBackgroundAttempt *active = AxsHeadsetBridgeKuwoBackgroundActive;
    BOOL holdingConsumed = active && !active.finished && active.lease == lease && active.preparationHold && now < active.preparationDeadline;
    if (!session || (consumed == session && !holdingConsumed) || expiry <= now || expiry - now > 23.0 || !axs_headsetbridge_kuwo_backgroundRoute()) return 0;
    return lease;
}

static void axs_headsetbridge_kuwo_reconcileBackgroundInternal(NSString *stage) {
    if (![NSThread isMainThread]) return;
    uint64_t lease = axs_headsetbridge_kuwo_backgroundLease();
    AxsHeadsetBridgeKuwoBackgroundAttempt *active = AxsHeadsetBridgeKuwoBackgroundActive;
    if (active && active.lease != lease) axs_headsetbridge_kuwo_backgroundEnd(active, @"lease_consumed_revoked_expired_or_route_lost");
    if (!lease || AxsHeadsetBridgeKuwoBackgroundActive) return;
    uint32_t session = (uint32_t)(lease >> 32);
    if (AxsHeadsetBridgeKuwoBackgroundLastSession == session) return;
    uint64_t attempted = 0;
    if (notify_get_state(AxsHeadsetBridgeKuwoBackgroundAttemptedToken, &attempted) != NOTIFY_STATUS_OK || attempted == lease) return;
    if (notify_set_state(AxsHeadsetBridgeKuwoBackgroundAttemptedToken, lease) != NOTIFY_STATUS_OK) return;
    AxsHeadsetBridgeKuwoBackgroundLastSession = session; // No retry, even across process restart in the same lease.
    if (axs_headsetbridge_kuwo_backgroundLease() != lease) return;
    AxsHeadsetBridgeKuwoBackgroundAttempt *attempt = [AxsHeadsetBridgeKuwoBackgroundAttempt new];
    attempt.identifier = UIBackgroundTaskInvalid;
    attempt.lease = lease;
    AxsHeadsetBridgeKuwoBackgroundActive = attempt;
    @try {
        UIBackgroundTaskIdentifier identifier = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"AxsHeadsetBridge-kuwo-current-connection" expirationHandler:^{
            void (^finish)(void) = ^{ axs_headsetbridge_kuwo_backgroundEnd(attempt, @"system_expiration"); };
            if ([NSThread isMainThread]) finish(); else dispatch_async(dispatch_get_main_queue(), finish);
        }];
        // Defend against expiration/revocation reentrancy while begin is returning.
        if (attempt.finished) {
            if (identifier != UIBackgroundTaskInvalid) [[UIApplication sharedApplication] endBackgroundTask:identifier];
            return;
        }
        attempt.identifier = identifier;
        axs_headsetbridge_kuwo_log(@"kuwo.background_task_begin", @{@"session": @(session), @"stage": stage, @"accepted": @(identifier != UIBackgroundTaskInvalid), @"expires_uptime": @((uint32_t)lease), @"remaining_lease_seconds": @((uint32_t)lease - [NSProcessInfo processInfo].systemUptime), @"note": @"UIKit identifier is not a wake/CPU-time guarantee; play authorization remains unchanged"});
        if (identifier == UIBackgroundTaskInvalid) { axs_headsetbridge_kuwo_backgroundEnd(attempt, @"request_denied"); return; }
        if (axs_headsetbridge_kuwo_backgroundLease() != lease) { axs_headsetbridge_kuwo_backgroundEnd(attempt, @"state_changed_during_begin"); return; }
        NSTimeInterval remaining = MAX(0.0, (uint32_t)lease - [NSProcessInfo processInfo].systemUptime);
        // One cutoff per task, not a keepalive/renewal loop. If main is blocked, dispatch is delayed.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            axs_headsetbridge_kuwo_backgroundEnd(attempt, @"original_lease_deadline");
        });
    } @catch (NSException *exception) {
        axs_headsetbridge_kuwo_backgroundEnd(attempt, @"begin_exception");
        axs_headsetbridge_kuwo_log(@"kuwo.background_task_exception", @{@"name": exception.name, @"session": @(session)});
    }
}

static void axs_headsetbridge_kuwo_startBackgroundInternal(void) {
    if (![NSThread isMainThread]) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uint32_t a = notify_register_dispatch(AxsHeadsetBridgeKuwoLease, &AxsHeadsetBridgeKuwoBackgroundLeaseToken, dispatch_get_main_queue(), ^(int token) {
            (void)token;
            axs_headsetbridge_kuwo_reconcileBackground(@"lease_changed");
        });
        uint32_t b = notify_register_check(AxsHeadsetBridgeKuwoConsumed, &AxsHeadsetBridgeKuwoBackgroundConsumedToken);
        uint32_t c = notify_register_check("com.axs.headsetbridge.kuwo.background-attempted-v7", &AxsHeadsetBridgeKuwoBackgroundAttemptedToken);
        AxsHeadsetBridgeKuwoBackgroundReady = a == NOTIFY_STATUS_OK && b == NOTIFY_STATUS_OK && c == NOTIFY_STATUS_OK;
        axs_headsetbridge_kuwo_log(@"kuwo.background_task_observer", @{@"lease_registration": @(a), @"consumed_registration": @(b), @"attempted_registration": @(c), @"ready": @(AxsHeadsetBridgeKuwoBackgroundReady)});
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        for (NSString *name in @[AVAudioSessionRouteChangeNotification, @"com.axs.headsetbridge.preferences-changed", UIApplicationDidEnterBackgroundNotification, UIApplicationWillTerminateNotification]) {
            [center addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                if ([note.name isEqual:UIApplicationWillTerminateNotification]) axs_headsetbridge_kuwo_backgroundEnd(AxsHeadsetBridgeKuwoBackgroundActive, @"app_terminating");
                else axs_headsetbridge_kuwo_reconcileBackground(note.name);
            }];
        }
        // Reads an already-published live lease, even before the first playback request arrives.
        axs_headsetbridge_kuwo_reconcileBackground(@"app_startup");
    });
}

// These APIs operate on an existing identifier only; they never request another task.
void axs_headsetbridge_kuwo_backgroundConsumed(uint64_t lease, BOOL forPlayback) {
    if (![NSThread isMainThread]) return;
    @try {
        AxsHeadsetBridgeKuwoBackgroundAttempt *attempt = AxsHeadsetBridgeKuwoBackgroundActive;
        if (!forPlayback) {
            axs_headsetbridge_kuwo_backgroundFinish(lease, @"consumed_without_new_play");
            axs_headsetbridge_kuwo_reconcileBackground(@"playback_opportunity_consumed");
            return;
        }
        // Do not renew a preparation window, even if a caller accidentally repeats consumption.
        if (attempt && attempt.lease == lease && !attempt.finished && !attempt.preparationHold && attempt.identifier != UIBackgroundTaskInvalid) {
            uint64_t currentLease = 0, consumed = 0;
            NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
            if (notify_get_state(AxsHeadsetBridgeKuwoBackgroundLeaseToken, &currentLease) != NOTIFY_STATUS_OK || currentLease != lease || notify_get_state(AxsHeadsetBridgeKuwoBackgroundConsumedToken, &consumed) != NOTIFY_STATUS_OK || consumed != (uint32_t)(lease >> 32) || (uint32_t)lease <= now || ![[AxsHeadsetBridgeKuwoConfig axs_headsetbridge_kuwo_shared] axs_headsetbridge_kuwo_isEnabled] || !axs_headsetbridge_kuwo_backgroundRoute() || !axs_headsetbridge_bindingValid(@"kuwo", lease)) {
                axs_headsetbridge_kuwo_backgroundEnd(attempt, @"preparation_not_eligible"); return;
            }
            attempt.preparationHold = YES;
            attempt.preparationDeadline = MIN((NSTimeInterval)(uint32_t)lease, now + 6.0);
            // Schedule before diagnostic logging so a logging exception cannot omit cleanup.
            NSTimeInterval remaining = MAX(0.0, attempt.preparationDeadline - now);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                axs_headsetbridge_kuwo_backgroundEnd(attempt, @"bounded_preparation_deadline");
            });
            axs_headsetbridge_kuwo_log(@"kuwo.background_preparation_hold", @{@"session": @((uint32_t)(lease >> 32)), @"hold_deadline_uptime": @(attempt.preparationDeadline), @"lease_deadline_uptime": @((uint32_t)lease), @"max_seconds": @6, @"note": @"Existing task only, no lease extension or second Play. Identifier does not prove audio preparation."});
        } else {
            axs_headsetbridge_kuwo_log(@"kuwo.background_preparation_unavailable", @{@"session": @((uint32_t)(lease >> 32)), @"note": @"No new task requested; normal single playback path continues"});
        }
        axs_headsetbridge_kuwo_reconcileBackground(@"consumed_for_single_play");
    } @catch (NSException *e) {
        axs_headsetbridge_kuwo_backgroundFinish(lease, @"preparation_exception");
        (void)e;
    }
}

void axs_headsetbridge_kuwo_backgroundFinish(uint64_t lease, NSString *reason) {
    if (![NSThread isMainThread]) return;
    @try {
        AxsHeadsetBridgeKuwoBackgroundAttempt *attempt = AxsHeadsetBridgeKuwoBackgroundActive;
        if (attempt && attempt.lease == lease) axs_headsetbridge_kuwo_backgroundEnd(attempt, reason);
    } @catch (NSException *e) { (void)e; }
}

void axs_headsetbridge_kuwo_reconcileBackground(NSString *stage) {
    @try { axs_headsetbridge_kuwo_reconcileBackgroundInternal(stage); }
    @catch (NSException *e) {
        axs_headsetbridge_kuwo_backgroundEnd(AxsHeadsetBridgeKuwoBackgroundActive, @"reconcile_exception");
        @try { axs_headsetbridge_kuwo_log(@"kuwo.background_task_exception", @{@"name":e.name, @"stage":stage}); } @catch (NSException *ignored) { (void)ignored; }
    }
}
void axs_headsetbridge_kuwo_startBackground(void) {
    @try { axs_headsetbridge_kuwo_startBackgroundInternal(); }
    @catch (NSException *e) {
        axs_headsetbridge_kuwo_backgroundEnd(AxsHeadsetBridgeKuwoBackgroundActive, @"setup_exception");
        (void)e;
    }
}
