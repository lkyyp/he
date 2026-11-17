#import "AxsHeadsetBridgeKuwoRuntime.h"
#import "AxsHeadsetBridgeKuwoConfig.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>
#import <unistd.h>
#import <stdlib.h>
#import <stdint.h>
#import <string.h>

static NSString * const AxsHeadsetBridgeKuwoTarget = @"com.yeelion.kwplayer";
static NSSet *AxsHeadsetBridgeKuwoAddresses;
static uint64_t AxsHeadsetBridgeKuwoObservedEpoch;
static NSUInteger AxsHeadsetBridgeKuwoGeneration;
static BOOL AxsHeadsetBridgeKuwoBusy;
static pid_t AxsHeadsetBridgeKuwoMusicPID;
static uint32_t AxsHeadsetBridgeKuwoChallenge;
static BOOL AxsHeadsetBridgeKuwoChallengePending;
static NSSet *AxsHeadsetBridgeKuwoSessionAddresses;
static int AxsHeadsetBridgeKuwoRequestToken = -1;
static int AxsHeadsetBridgeKuwoLeaseWriter = -1;
static uint64_t AxsHeadsetBridgeKuwoLeaseState;
static void (*AxsHeadsetBridgeKuwoGetPID)(dispatch_queue_t, void (^)(pid_t));
static void (*AxsHeadsetBridgeKuwoGetPlaying)(dispatch_queue_t, void (^)(Boolean));

static BOOL axs_headsetbridge_kuwo_systemSignature(id receiver, SEL sel, const char *returns, NSUInteger arguments) {
    if (!receiver || ![receiver respondsToSelector:sel]) return NO;
    NSMethodSignature *sig = [receiver methodSignatureForSelector:sel];
    return sig && sig.numberOfArguments == arguments && strlen(sig.methodReturnType) == 1 && strchr(returns, sig.methodReturnType[0]) != NULL;
}
static id axs_headsetbridge_kuwo_callObject(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!axs_headsetbridge_kuwo_systemSignature(receiver, selector, "@", 2)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static void axs_headsetbridge_kuwo_preflight(NSUInteger generation, NSString *stage) {
    NSMutableDictionary *fields = [@{@"generation": @(generation), @"stage": stage, @"running_known": @NO} mutableCopy];
    @try {
        id controller = axs_headsetbridge_kuwo_callObject(objc_getClass("SBApplicationController"), @"sharedInstance");
        fields[@"controller_class_loaded"] = @(objc_getClass("SBApplicationController") != Nil);
        fields[@"controller_obtained"] = @(controller != nil);
        SEL lookup = NSSelectorFromString(@"applicationWithBundleIdentifier:");
        NSMethodSignature *signature = [controller methodSignatureForSelector:lookup];
        fields[@"lookup_supported"] = @([controller respondsToSelector:lookup]);
        fields[@"lookup_encoding"] = signature ? [NSString stringWithUTF8String:signature.methodReturnType] : @"unavailable";
        if (axs_headsetbridge_kuwo_systemSignature(controller, lookup, "@", 3) && strcmp([signature getArgumentTypeAtIndex:2], "@") == 0) {
            id application = ((id (*)(id, SEL, id))objc_msgSend)(controller, lookup, AxsHeadsetBridgeKuwoTarget);
            fields[@"application_obtained"] = @(application != nil);
            fields[@"application_class"] = application ? NSStringFromClass([application class]) : @"nil";
            SEL running = NSSelectorFromString(@"isRunning");
            NSMethodSignature *runningSignature = [application methodSignatureForSelector:running];
            fields[@"isRunning_supported"] = @([application respondsToSelector:running]);
            fields[@"isRunning_return_encoding"] = runningSignature ? [NSString stringWithUTF8String:runningSignature.methodReturnType] : @"unavailable";
            if (runningSignature && runningSignature.numberOfArguments == 2 && (runningSignature.methodReturnType[0] == 'B' || runningSignature.methodReturnType[0] == 'c')) {
                fields[@"running_known"] = @YES;
                fields[@"running"] = @(((BOOL (*)(id, SEL))objc_msgSend)(application, running));
            }
        }
    } @catch (NSException *exception) { fields[@"exception"] = exception.name; }
    fields[@"note"] = @"Advisory SpringBoard state; independently confirm no process before cold-start test.";
    axs_headsetbridge_kuwo_log(@"sb.target_preflight", fields);
}

static NSArray *axs_headsetbridge_kuwo_audioDevices(void) {
    id manager = axs_headsetbridge_kuwo_callObject(objc_getClass("BluetoothManager"), @"sharedInstance");
    id devices = axs_headsetbridge_kuwo_callObject(manager, @"connectedDevices");
    if (![devices isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *audio = [NSMutableArray array];
    for (id device in devices) {
        BOOL isAudio = NO;
        for (NSString *name in @[@"supportsA2DP", @"isHeadsetDevice", @"isAppleAudioDevice"]) {
            SEL sel = NSSelectorFromString(name);
            if (axs_headsetbridge_kuwo_systemSignature(device, sel, "Bc", 2) && ((BOOL (*)(id, SEL))objc_msgSend)(device, sel)) isAudio = YES;
        }
        SEL majorSEL = NSSelectorFromString(@"majorClass");
        if (axs_headsetbridge_kuwo_systemSignature(device, majorSEL, "Ii", 2)) {
            unsigned int major = ((unsigned int (*)(id, SEL))objc_msgSend)(device, majorSEL);
            if (major > 0x1f) major = (major >> 8) & 0x1f;
            if (major == 4) isAudio = YES;
        }
        if (isAudio) [audio addObject:device];
    }
    return audio;
}

static NSSet *axs_headsetbridge_kuwo_addresses(void) {
    NSMutableSet *set = [NSMutableSet set];
    for (id device in axs_headsetbridge_kuwo_audioDevices()) {
        id address = axs_headsetbridge_kuwo_callObject(device, @"address");
        // Address is used only in memory for deduplication, never written to logs.
        if ([address isKindOfClass:[NSString class]] && [address length]) [set addObject:address];
    }
    return set;
}

static BOOL axs_headsetbridge_kuwo_valid(NSUInteger generation) {
    return generation == AxsHeadsetBridgeKuwoGeneration && AxsHeadsetBridgeKuwoBusy &&
        [[AxsHeadsetBridgeKuwoConfig axs_headsetbridge_kuwo_shared] axs_headsetbridge_kuwo_isEnabled] &&
        [axs_headsetbridge_kuwo_addresses() isEqualToSet:AxsHeadsetBridgeKuwoSessionAddresses] &&
        axs_headsetbridge_bindingValid(@"kuwo", AxsHeadsetBridgeKuwoLeaseState);
}

static void axs_headsetbridge_kuwo_revokeLease(void) {
    axs_headsetbridge_revokeBinding(@"kuwo");
    AxsHeadsetBridgeKuwoLeaseState = 0;
    if (AxsHeadsetBridgeKuwoLeaseWriter >= 0 && notify_set_state(AxsHeadsetBridgeKuwoLeaseWriter, 0) == NOTIFY_STATUS_OK) notify_post(AxsHeadsetBridgeKuwoLease);
}

static void axs_headsetbridge_kuwo_sample(NSUInteger generation, NSNumber *second) {
    if (!axs_headsetbridge_kuwo_valid(generation)) {
        if (generation == AxsHeadsetBridgeKuwoGeneration) axs_headsetbridge_kuwo_revokeLease();
        return;
    }
    AxsHeadsetBridgeKuwoChallenge = arc4random_uniform(UINT32_MAX - 1) + 1;
    AxsHeadsetBridgeKuwoChallengePending = YES;
    uint32_t stateResult = notify_set_state(AxsHeadsetBridgeKuwoRequestToken, (AxsHeadsetBridgeKuwoLeaseState & 0xffffffff00000000ULL) | AxsHeadsetBridgeKuwoChallenge);
    uint32_t posted = stateResult == NOTIFY_STATUS_OK ? notify_post(AxsHeadsetBridgeKuwoRequest) : stateResult;
    axs_headsetbridge_kuwo_log(@"sb.probe", @{@"generation": @(generation), @"second": second, @"challenge": @(AxsHeadsetBridgeKuwoChallenge), @"notify_result": @(posted), @"reported_pid": @(AxsHeadsetBridgeKuwoMusicPID)});
    if (posted != NOTIFY_STATUS_OK) { AxsHeadsetBridgeKuwoChallengePending = NO; return; }
    uint32_t challenge = AxsHeadsetBridgeKuwoChallenge;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (challenge == AxsHeadsetBridgeKuwoChallenge) AxsHeadsetBridgeKuwoChallengePending = NO;
    });
    if (!AxsHeadsetBridgeKuwoGetPID || !AxsHeadsetBridgeKuwoGetPlaying) return;
    AxsHeadsetBridgeKuwoGetPID(dispatch_get_main_queue(), ^(pid_t mediaPID) {
        if (!axs_headsetbridge_kuwo_valid(generation)) return;
        AxsHeadsetBridgeKuwoGetPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            if (!axs_headsetbridge_kuwo_valid(generation)) return;
            BOOL target = AxsHeadsetBridgeKuwoMusicPID > 0 && mediaPID == AxsHeadsetBridgeKuwoMusicPID;
            axs_headsetbridge_kuwo_log(@"sb.media_state", @{@"generation": @(generation), @"media_pid": @(mediaPID), @"ack_pid": @(AxsHeadsetBridgeKuwoMusicPID), @"target_matches": @(target), @"playing": @(playing), @"second": second});
            if (target) {
                axs_headsetbridge_kuwo_log(@"sb.reported_pid_matches_media", @{@"generation": @(generation), @"playing_snapshot": @(playing), @"note": @"Unauthenticated app-reported PID and non-atomic media snapshots; not proof of success. SpringBoard sends no global Play command."});
            }
        });
    });
}

static void axs_headsetbridge_kuwo_begin(void) {
    if (AxsHeadsetBridgeKuwoBusy || ![[AxsHeadsetBridgeKuwoConfig axs_headsetbridge_kuwo_shared] axs_headsetbridge_kuwo_isEnabled]) return;
    AxsHeadsetBridgeKuwoBusy = YES;
    AxsHeadsetBridgeKuwoMusicPID = 0;
    AxsHeadsetBridgeKuwoChallengePending = NO;
    AxsHeadsetBridgeKuwoSessionAddresses = [axs_headsetbridge_kuwo_addresses() copy];
    NSUInteger generation = ++AxsHeadsetBridgeKuwoGeneration;
    uint32_t nonce = arc4random_uniform(UINT32_MAX - 1) + 1;
    uint32_t expires = (uint32_t)([NSProcessInfo processInfo].systemUptime + 23.0);
    AxsHeadsetBridgeKuwoLeaseState = ((uint64_t)nonce << 32) | expires;
    if (!axs_headsetbridge_publishBinding(@"kuwo", AxsHeadsetBridgeKuwoLeaseState, AxsHeadsetBridgeKuwoObservedEpoch)) {
        axs_headsetbridge_kuwo_revokeLease(); AxsHeadsetBridgeKuwoBusy = NO; return;
    }
    uint32_t leaseResult = notify_set_state(AxsHeadsetBridgeKuwoLeaseWriter, AxsHeadsetBridgeKuwoLeaseState);
    axs_headsetbridge_kuwo_log(@"sb.playback_lease", @{@"session": @(nonce), @"expires_uptime": @(expires), @"notify_result": @(leaseResult), @"note": @"Freshness coordination only, not authenticated IPC"});
    if (leaseResult != NOTIFY_STATUS_OK) axs_headsetbridge_kuwo_revokeLease();
    else {
        uint32_t posted = notify_post(AxsHeadsetBridgeKuwoLease);
        axs_headsetbridge_kuwo_log(@"sb.background_lease_signal", @{@"session": @(nonce), @"notify_result": @(posted)});
    }
    axs_headsetbridge_kuwo_log(@"sb.session_begin", @{@"generation": @(generation)});
    axs_headsetbridge_kuwo_preflight(generation, @"connection");
    axs_headsetbridge_kuwo_observeProcesses(nonce, @"connection_scan_requested");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!axs_headsetbridge_kuwo_valid(generation)) return;
        axs_headsetbridge_kuwo_preflight(generation, @"before_launch");
        axs_headsetbridge_kuwo_observeProcesses(nonce, @"launch_time_async_scan_requested");
        UIApplication *app = [UIApplication sharedApplication];
        SEL launch = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
        NSMethodSignature *launchSig = [app methodSignatureForSelector:launch];
        BOOL launchABI = axs_headsetbridge_kuwo_systemSignature(app, launch, "Bcv", 4) && strcmp([launchSig getArgumentTypeAtIndex:2], "@") == 0 && (strcmp([launchSig getArgumentTypeAtIndex:3], "B") == 0 || strcmp([launchSig getArgumentTypeAtIndex:3], "c") == 0);
        if (!axs_headsetbridge_kuwo_valid(generation)) return;
        if (launchABI) {
            @try {
                if (launchSig.methodReturnType[0] == 'v') {
                    ((void (*)(id, SEL, NSString *, BOOL))objc_msgSend)(app, launch, AxsHeadsetBridgeKuwoTarget, YES);
                    axs_headsetbridge_kuwo_log(@"sb.launch_request", @{@"generation": @(generation), @"suspended": @YES, @"return_kind": @"void", @"note": @"No return value; request is not proof of execution"});
                } else {
                    BOOL returned = ((BOOL (*)(id, SEL, NSString *, BOOL))objc_msgSend)(app, launch, AxsHeadsetBridgeKuwoTarget, YES);
                    axs_headsetbridge_kuwo_log(@"sb.launch_request", @{@"generation": @(generation), @"suspended": @YES, @"returned": @(returned), @"note": @"request return is not proof of execution"});
                }
            } @catch (NSException *exception) {
                axs_headsetbridge_kuwo_log(@"sb.launch_exception", @{@"name": exception.name});
            }
        } else {
            axs_headsetbridge_kuwo_log(@"sb.launch_api_unavailable", @{@"generation": @(generation), @"reason": @"missing_or_unrecognized_signature"});
        }
        for (NSNumber *second in @[@1, @3, @6, @10, @16]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(second.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                axs_headsetbridge_kuwo_sample(generation, second);
            });
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (axs_headsetbridge_kuwo_valid(generation)) axs_headsetbridge_kuwo_observeProcesses(nonce, @"connection_plus_8s");
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 23 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (generation != AxsHeadsetBridgeKuwoGeneration) return;
        axs_headsetbridge_kuwo_log(@"sb.session_end", @{@"generation": @(generation), @"music_ack_seen": @(AxsHeadsetBridgeKuwoMusicPID > 0), @"note": @"No ack means not observed within deadline; cause unknown. Internal playback results are in app log."});
        AxsHeadsetBridgeKuwoChallengePending = NO;
        AxsHeadsetBridgeKuwoBusy = NO;
        axs_headsetbridge_kuwo_revokeLease();
    });
}

static void axs_headsetbridge_kuwo_connectionsChanged(void) {
    NSSet *current = axs_headsetbridge_kuwo_addresses();
    uint64_t epoch = axs_headsetbridge_configurationEpoch();
    if (AxsHeadsetBridgeKuwoObservedEpoch != epoch) {
        if (AxsHeadsetBridgeKuwoBusy && !axs_headsetbridge_bindingValid(@"kuwo", AxsHeadsetBridgeKuwoLeaseState)) {
            ++AxsHeadsetBridgeKuwoGeneration;
            AxsHeadsetBridgeKuwoBusy = NO;
            AxsHeadsetBridgeKuwoChallengePending = NO;
            AxsHeadsetBridgeKuwoMusicPID = 0;
            axs_headsetbridge_kuwo_revokeLease();
        }
        AxsHeadsetBridgeKuwoObservedEpoch = epoch;
        AxsHeadsetBridgeKuwoAddresses = current;
        // A configuration change only re-baselines; never replay an already-connected device.
        return;
    }
    if (!AxsHeadsetBridgeKuwoAddresses) {
        AxsHeadsetBridgeKuwoAddresses = current;
        axs_headsetbridge_kuwo_log(@"sb.baseline", @{@"audio_count": @(current.count)});
        return;
    }
    NSMutableSet *added = [current mutableCopy];
    [added minusSet:AxsHeadsetBridgeKuwoAddresses];
    BOOL changed = ![current isEqualToSet:AxsHeadsetBridgeKuwoAddresses];
    AxsHeadsetBridgeKuwoAddresses = current;
    if (changed) axs_headsetbridge_kuwo_log(@"sb.bluetooth_changed", @{@"audio_count": @(current.count), @"added_count": @(added.count)});
    if (changed && AxsHeadsetBridgeKuwoBusy) {
        ++AxsHeadsetBridgeKuwoGeneration;
        AxsHeadsetBridgeKuwoBusy = NO;
        axs_headsetbridge_kuwo_revokeLease();
        AxsHeadsetBridgeKuwoChallengePending = NO;
        AxsHeadsetBridgeKuwoMusicPID = 0;
        axs_headsetbridge_kuwo_log(@"sb.session_cancelled", @{@"reason": @"audio_device_set_changed"});
    }
    if (added.count > 0) axs_headsetbridge_kuwo_begin();
}

void axs_headsetbridge_kuwo_startSpringBoard(void) {
    NSOperatingSystemVersion os = [NSProcessInfo processInfo].operatingSystemVersion;
    axs_headsetbridge_kuwo_log(@"sb.injected", @{@"system": [UIDevice currentDevice].systemVersion, @"os_major": @(os.majorVersion), @"os_minor": @(os.minorVersion), @"os_patch": @(os.patchVersion), @"os_description": [NSProcessInfo processInfo].operatingSystemVersionString, @"log_path": axs_headsetbridge_kuwo_logPath()});
    if (!objc_getClass("BluetoothManager")) {
        void *bluetooth = dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY);
        axs_headsetbridge_kuwo_log(@"sb.bluetooth_framework_load", @{@"loaded": @(bluetooth != NULL)});
    }
    id manager = axs_headsetbridge_kuwo_callObject(objc_getClass("BluetoothManager"), @"sharedInstance");
    BOOL observable = manager && [manager respondsToSelector:NSSelectorFromString(@"connectedDevices")];
    axs_headsetbridge_kuwo_log(@"sb.bluetooth_observable", @{@"supported": @(observable), @"note": @"Notification delivery and private method ABI still require device testing"});
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (handle) {
        AxsHeadsetBridgeKuwoGetPID = (void (*)(dispatch_queue_t, void (^)(pid_t)))dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
        AxsHeadsetBridgeKuwoGetPlaying = (void (*)(dispatch_queue_t, void (^)(Boolean)))dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    }
    axs_headsetbridge_kuwo_log(@"sb.api_availability", @{@"media_pid": @(AxsHeadsetBridgeKuwoGetPID != NULL), @"media_playing": @(AxsHeadsetBridgeKuwoGetPlaying != NULL), @"app_internal_playback_experiment": @YES, @"bluetooth_manager": @(objc_getClass("BluetoothManager") != Nil)});
    uint32_t leaseRegistration = notify_register_check(AxsHeadsetBridgeKuwoLease, &AxsHeadsetBridgeKuwoLeaseWriter);
    axs_headsetbridge_kuwo_revokeLease();
    axs_headsetbridge_kuwo_log(@"sb.lease_writer", @{@"registration": @(leaseRegistration)});
    uint32_t requestResult = notify_register_check(AxsHeadsetBridgeKuwoRequest, &AxsHeadsetBridgeKuwoRequestToken);
    static int ackToken;
    uint32_t ackResult = notify_register_dispatch(AxsHeadsetBridgeKuwoAck, &ackToken, dispatch_get_main_queue(), ^(int token) {
        if (!AxsHeadsetBridgeKuwoBusy) return;
        uint64_t state = 0;
        uint32_t result = notify_get_state(token, &state);
        uint32_t generation = (uint32_t)(state >> 32);
        uint32_t low = (uint32_t)state;
        pid_t pid = (pid_t)(low & 0x7fffffffU);
        BOOL bluetooth = (low & 0x80000000U) != 0;
        if (result != NOTIFY_STATUS_OK || !AxsHeadsetBridgeKuwoChallengePending || generation != AxsHeadsetBridgeKuwoChallenge || pid <= 0) {
            axs_headsetbridge_kuwo_log(@"sb.ack_rejected", @{@"notify_result": @(result), @"ack_generation": @(generation)});
            return;
        }
        AxsHeadsetBridgeKuwoMusicPID = pid;
        AxsHeadsetBridgeKuwoChallengePending = NO;
        axs_headsetbridge_kuwo_log(@"sb.music_ack", @{@"generation": @(AxsHeadsetBridgeKuwoGeneration), @"challenge": @(generation), @"reported_music_pid": @(pid), @"reported_bluetooth_route": @(bluetooth), @"note": @"Diagnostic hint, not authenticated process identity"});
    });
    axs_headsetbridge_kuwo_log(@"sb.ipc_observers", @{@"request_result": @(requestResult), @"ack_result": @(ackResult)});
    AxsHeadsetBridgeKuwoAddresses = axs_headsetbridge_kuwo_addresses();
    AxsHeadsetBridgeKuwoObservedEpoch = axs_headsetbridge_configurationEpoch();
    axs_headsetbridge_kuwo_log(@"sb.baseline", @{@"audio_count": @(AxsHeadsetBridgeKuwoAddresses.count)});
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:@"com.axs.headsetbridge.preferences-changed" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        (void)note;
        uint64_t epoch = axs_headsetbridge_configurationEpoch();
        if (AxsHeadsetBridgeKuwoObservedEpoch != epoch) {
            AxsHeadsetBridgeKuwoObservedEpoch = epoch;
            AxsHeadsetBridgeKuwoAddresses = axs_headsetbridge_kuwo_addresses();
        }
        if (AxsHeadsetBridgeKuwoBusy && !axs_headsetbridge_bindingValid(@"kuwo", AxsHeadsetBridgeKuwoLeaseState)) {
            ++AxsHeadsetBridgeKuwoGeneration;
            AxsHeadsetBridgeKuwoBusy = NO;
        axs_headsetbridge_kuwo_revokeLease();
            AxsHeadsetBridgeKuwoChallengePending = NO;
            AxsHeadsetBridgeKuwoMusicPID = 0;
            axs_headsetbridge_kuwo_log(@"sb.session_cancelled", @{@"reason": @"disabled"});
        }
    }];
    for (NSString *name in @[@"BluetoothDeviceConnectSuccessNotification", @"BluetoothDeviceDisconnectSuccessNotification"]) {
        [center addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            (void)note;
            axs_headsetbridge_kuwo_connectionsChanged();
        }];
    }
    [center addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        axs_headsetbridge_kuwo_log(@"sb.local_route_changed", @{@"reason": note.userInfo[AVAudioSessionRouteChangeReasonKey] ?: @0, @"note": @"SpringBoard route is not proof of music app output"});
        axs_headsetbridge_kuwo_connectionsChanged();
    }];
    // Runtime metadata only. No new resume/open/assertion method is invoked.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if ([[AxsHeadsetBridgeKuwoConfig axs_headsetbridge_kuwo_shared] axs_headsetbridge_kuwo_isEnabled]) axs_headsetbridge_kuwo_collectSystemInterfaces();
    });
    // No permanent poll timer; baseline and connection notifications only.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        axs_headsetbridge_kuwo_connectionsChanged();
    });
}
