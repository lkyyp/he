#import "AxsHeadsetBridgeCloudRuntime.h"
#import "AxsHeadsetBridgeCloudConfig.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>
#import <unistd.h>
#import <stdlib.h>
#import <stdint.h>

static NSString * const AxsHeadsetBridgeCloudTarget = @"com.netease.cloudmusic";
static NSSet *AxsHeadsetBridgeCloudAddresses;
static uint64_t AxsHeadsetBridgeCloudObservedEpoch;
static NSUInteger AxsHeadsetBridgeCloudGeneration;
static BOOL AxsHeadsetBridgeCloudBusy;
static pid_t AxsHeadsetBridgeCloudMusicPID;
static uint32_t AxsHeadsetBridgeCloudChallenge;
static BOOL AxsHeadsetBridgeCloudChallengePending;
static NSSet *AxsHeadsetBridgeCloudSessionAddresses;
static int AxsHeadsetBridgeCloudRequestToken = -1;
static int AxsHeadsetBridgeCloudLeaseWriter = -1;
static uint64_t AxsHeadsetBridgeCloudLeaseState;
static void (*AxsHeadsetBridgeCloudGetPID)(dispatch_queue_t, void (^)(pid_t));
static void (*AxsHeadsetBridgeCloudGetPlaying)(dispatch_queue_t, void (^)(Boolean));

static id axs_headsetbridge_cloud_callObject(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!receiver || ![receiver respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static void axs_headsetbridge_cloud_preflight(NSUInteger generation, NSString *stage) {
    NSMutableDictionary *fields = [@{@"generation": @(generation), @"stage": stage, @"running_known": @NO} mutableCopy];
    @try {
        id controller = axs_headsetbridge_cloud_callObject(objc_getClass("SBApplicationController"), @"sharedInstance");
        SEL lookup = NSSelectorFromString(@"applicationWithBundleIdentifier:");
        NSMethodSignature *signature = [controller methodSignatureForSelector:lookup];
        if (signature && signature.numberOfArguments == 3 && signature.methodReturnType[0] == '@') {
            id application = ((id (*)(id, SEL, id))objc_msgSend)(controller, lookup, AxsHeadsetBridgeCloudTarget);
            SEL running = NSSelectorFromString(@"isRunning");
            NSMethodSignature *runningSignature = [application methodSignatureForSelector:running];
            if (runningSignature && runningSignature.numberOfArguments == 2 && (runningSignature.methodReturnType[0] == 'B' || runningSignature.methodReturnType[0] == 'c')) {
                fields[@"running_known"] = @YES;
                fields[@"running"] = @(((BOOL (*)(id, SEL))objc_msgSend)(application, running));
            }
        }
    } @catch (NSException *exception) { fields[@"exception"] = exception.name; }
    fields[@"note"] = @"Advisory SpringBoard state; independently confirm no process before cold-start test.";
    axs_headsetbridge_cloud_log(@"sb.target_preflight", fields);
}

static NSArray *axs_headsetbridge_cloud_audioDevices(void) {
    id manager = axs_headsetbridge_cloud_callObject(objc_getClass("BluetoothManager"), @"sharedInstance");
    id devices = axs_headsetbridge_cloud_callObject(manager, @"connectedDevices");
    if (![devices isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *audio = [NSMutableArray array];
    for (id device in devices) {
        BOOL isAudio = NO;
        for (NSString *name in @[@"supportsA2DP", @"isHeadsetDevice", @"isAppleAudioDevice"]) {
            SEL sel = NSSelectorFromString(name);
            if ([device respondsToSelector:sel] && ((BOOL (*)(id, SEL))objc_msgSend)(device, sel)) isAudio = YES;
        }
        SEL majorSEL = NSSelectorFromString(@"majorClass");
        if ([device respondsToSelector:majorSEL]) {
            unsigned int major = ((unsigned int (*)(id, SEL))objc_msgSend)(device, majorSEL);
            if (major > 0x1f) major = (major >> 8) & 0x1f;
            if (major == 4) isAudio = YES;
        }
        if (isAudio) [audio addObject:device];
    }
    return audio;
}

static NSSet *axs_headsetbridge_cloud_addresses(void) {
    NSMutableSet *set = [NSMutableSet set];
    for (id device in axs_headsetbridge_cloud_audioDevices()) {
        id address = axs_headsetbridge_cloud_callObject(device, @"address");
        // Address is used only in memory for deduplication, never written to logs.
        if ([address isKindOfClass:[NSString class]] && [address length]) [set addObject:address];
    }
    return set;
}

static BOOL axs_headsetbridge_cloud_valid(NSUInteger generation) {
    return generation == AxsHeadsetBridgeCloudGeneration && AxsHeadsetBridgeCloudBusy &&
        [[AxsHeadsetBridgeCloudConfig axs_headsetbridge_cloud_shared] axs_headsetbridge_cloud_isEnabled] &&
        [axs_headsetbridge_cloud_addresses() isEqualToSet:AxsHeadsetBridgeCloudSessionAddresses] &&
        axs_headsetbridge_bindingValid(@"cloud", AxsHeadsetBridgeCloudLeaseState);
}

static void axs_headsetbridge_cloud_revokeLease(void) {
    axs_headsetbridge_revokeBinding(@"cloud");
    AxsHeadsetBridgeCloudLeaseState = 0;
    if (AxsHeadsetBridgeCloudLeaseWriter >= 0) notify_set_state(AxsHeadsetBridgeCloudLeaseWriter, 0);
}

static void axs_headsetbridge_cloud_sample(NSUInteger generation, NSNumber *second) {
    if (!axs_headsetbridge_cloud_valid(generation)) {
        if (generation == AxsHeadsetBridgeCloudGeneration) axs_headsetbridge_cloud_revokeLease();
        return;
    }
    AxsHeadsetBridgeCloudChallenge = arc4random_uniform(UINT32_MAX - 1) + 1;
    AxsHeadsetBridgeCloudChallengePending = YES;
    uint32_t stateResult = notify_set_state(AxsHeadsetBridgeCloudRequestToken, (AxsHeadsetBridgeCloudLeaseState & 0xffffffff00000000ULL) | AxsHeadsetBridgeCloudChallenge);
    uint32_t posted = stateResult == NOTIFY_STATUS_OK ? notify_post(AxsHeadsetBridgeCloudRequest) : stateResult;
    axs_headsetbridge_cloud_log(@"sb.probe", @{@"generation": @(generation), @"second": second, @"challenge": @(AxsHeadsetBridgeCloudChallenge), @"notify_result": @(posted), @"reported_pid": @(AxsHeadsetBridgeCloudMusicPID)});
    if (posted != NOTIFY_STATUS_OK) { AxsHeadsetBridgeCloudChallengePending = NO; return; }
    uint32_t challenge = AxsHeadsetBridgeCloudChallenge;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (challenge == AxsHeadsetBridgeCloudChallenge) AxsHeadsetBridgeCloudChallengePending = NO;
    });
    if (!AxsHeadsetBridgeCloudGetPID || !AxsHeadsetBridgeCloudGetPlaying) return;
    AxsHeadsetBridgeCloudGetPID(dispatch_get_main_queue(), ^(pid_t mediaPID) {
        if (!axs_headsetbridge_cloud_valid(generation)) return;
        AxsHeadsetBridgeCloudGetPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            if (!axs_headsetbridge_cloud_valid(generation)) return;
            BOOL target = AxsHeadsetBridgeCloudMusicPID > 0 && mediaPID == AxsHeadsetBridgeCloudMusicPID;
            axs_headsetbridge_cloud_log(@"sb.media_state", @{@"generation": @(generation), @"media_pid": @(mediaPID), @"ack_pid": @(AxsHeadsetBridgeCloudMusicPID), @"target_matches": @(target), @"playing": @(playing), @"second": second});
            if (target) {
                axs_headsetbridge_cloud_log(@"sb.reported_pid_matches_media", @{@"generation": @(generation), @"playing_snapshot": @(playing), @"note": @"Unauthenticated app-reported PID and non-atomic media snapshots; not proof of success. SpringBoard sends no global Play command."});
            }
        });
    });
}

static void axs_headsetbridge_cloud_begin(void) {
    if (AxsHeadsetBridgeCloudBusy || ![[AxsHeadsetBridgeCloudConfig axs_headsetbridge_cloud_shared] axs_headsetbridge_cloud_isEnabled]) return;
    AxsHeadsetBridgeCloudBusy = YES;
    AxsHeadsetBridgeCloudMusicPID = 0;
    AxsHeadsetBridgeCloudChallengePending = NO;
    AxsHeadsetBridgeCloudSessionAddresses = [axs_headsetbridge_cloud_addresses() copy];
    NSUInteger generation = ++AxsHeadsetBridgeCloudGeneration;
    uint32_t nonce = arc4random_uniform(UINT32_MAX - 1) + 1;
    uint32_t expires = (uint32_t)([NSProcessInfo processInfo].systemUptime + 23.0);
    AxsHeadsetBridgeCloudLeaseState = ((uint64_t)nonce << 32) | expires;
    if (!axs_headsetbridge_publishBinding(@"cloud", AxsHeadsetBridgeCloudLeaseState, AxsHeadsetBridgeCloudObservedEpoch)) {
        axs_headsetbridge_cloud_revokeLease(); AxsHeadsetBridgeCloudBusy = NO; return;
    }
    uint32_t leaseResult = notify_set_state(AxsHeadsetBridgeCloudLeaseWriter, AxsHeadsetBridgeCloudLeaseState);
    axs_headsetbridge_cloud_log(@"sb.playback_lease", @{@"session": @(nonce), @"expires_uptime": @(expires), @"notify_result": @(leaseResult), @"note": @"Freshness coordination only, not authenticated IPC"});
    if (leaseResult != NOTIFY_STATUS_OK) axs_headsetbridge_cloud_revokeLease();
    axs_headsetbridge_cloud_log(@"sb.session_begin", @{@"generation": @(generation)});
    axs_headsetbridge_cloud_preflight(generation, @"connection");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!axs_headsetbridge_cloud_valid(generation)) return;
        axs_headsetbridge_cloud_preflight(generation, @"before_launch");
        UIApplication *app = [UIApplication sharedApplication];
        SEL launch = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
        if (!axs_headsetbridge_cloud_valid(generation)) return;
        if ([app respondsToSelector:launch]) {
            @try {
                BOOL returned = ((BOOL (*)(id, SEL, NSString *, BOOL))objc_msgSend)(app, launch, AxsHeadsetBridgeCloudTarget, YES);
                axs_headsetbridge_cloud_log(@"sb.launch_request", @{@"generation": @(generation), @"suspended": @YES, @"returned": @(returned), @"note": @"request return is not proof of execution"});
            } @catch (NSException *exception) {
                axs_headsetbridge_cloud_log(@"sb.launch_exception", @{@"name": exception.name});
            }
        } else {
            axs_headsetbridge_cloud_log(@"sb.launch_api_unavailable", @{@"generation": @(generation)});
        }
        for (NSNumber *second in @[@1, @3, @6, @10, @16]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(second.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                axs_headsetbridge_cloud_sample(generation, second);
            });
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 23 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (generation != AxsHeadsetBridgeCloudGeneration) return;
        axs_headsetbridge_cloud_log(@"sb.session_end", @{@"generation": @(generation), @"music_ack_seen": @(AxsHeadsetBridgeCloudMusicPID > 0), @"note": @"No ack means not observed within deadline; cause unknown. Internal playback results are in app log."});
        AxsHeadsetBridgeCloudChallengePending = NO;
        AxsHeadsetBridgeCloudBusy = NO;
        axs_headsetbridge_cloud_revokeLease();
    });
}

static void axs_headsetbridge_cloud_connectionsChanged(void) {
    NSSet *current = axs_headsetbridge_cloud_addresses();
    uint64_t epoch = axs_headsetbridge_configurationEpoch();
    if (AxsHeadsetBridgeCloudObservedEpoch != epoch) {
        if (AxsHeadsetBridgeCloudBusy && !axs_headsetbridge_bindingValid(@"cloud", AxsHeadsetBridgeCloudLeaseState)) {
            ++AxsHeadsetBridgeCloudGeneration;
            AxsHeadsetBridgeCloudBusy = NO;
            AxsHeadsetBridgeCloudChallengePending = NO;
            AxsHeadsetBridgeCloudMusicPID = 0;
            axs_headsetbridge_cloud_revokeLease();
        }
        AxsHeadsetBridgeCloudObservedEpoch = epoch;
        AxsHeadsetBridgeCloudAddresses = current;
        // A configuration change only re-baselines; never replay an already-connected device.
        return;
    }
    if (!AxsHeadsetBridgeCloudAddresses) {
        AxsHeadsetBridgeCloudAddresses = current;
        axs_headsetbridge_cloud_log(@"sb.baseline", @{@"audio_count": @(current.count)});
        return;
    }
    NSMutableSet *added = [current mutableCopy];
    [added minusSet:AxsHeadsetBridgeCloudAddresses];
    BOOL changed = ![current isEqualToSet:AxsHeadsetBridgeCloudAddresses];
    AxsHeadsetBridgeCloudAddresses = current;
    if (changed) axs_headsetbridge_cloud_log(@"sb.bluetooth_changed", @{@"audio_count": @(current.count), @"added_count": @(added.count)});
    if (changed && AxsHeadsetBridgeCloudBusy) {
        ++AxsHeadsetBridgeCloudGeneration;
        AxsHeadsetBridgeCloudBusy = NO;
        axs_headsetbridge_cloud_revokeLease();
        AxsHeadsetBridgeCloudChallengePending = NO;
        AxsHeadsetBridgeCloudMusicPID = 0;
        axs_headsetbridge_cloud_log(@"sb.session_cancelled", @{@"reason": @"audio_device_set_changed"});
    }
    if (added.count > 0) axs_headsetbridge_cloud_begin();
}

void axs_headsetbridge_cloud_startSpringBoard(void) {
    NSOperatingSystemVersion os = [NSProcessInfo processInfo].operatingSystemVersion;
    axs_headsetbridge_cloud_log(@"sb.injected", @{@"system": [UIDevice currentDevice].systemVersion, @"os_major": @(os.majorVersion), @"os_minor": @(os.minorVersion), @"os_patch": @(os.patchVersion), @"os_description": [NSProcessInfo processInfo].operatingSystemVersionString, @"log_path": axs_headsetbridge_cloud_logPath()});
    if (!objc_getClass("BluetoothManager")) {
        void *bluetooth = dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY);
        axs_headsetbridge_cloud_log(@"sb.bluetooth_framework_load", @{@"loaded": @(bluetooth != NULL)});
    }
    id manager = axs_headsetbridge_cloud_callObject(objc_getClass("BluetoothManager"), @"sharedInstance");
    BOOL observable = manager && [manager respondsToSelector:NSSelectorFromString(@"connectedDevices")];
    axs_headsetbridge_cloud_log(@"sb.bluetooth_observable", @{@"supported": @(observable), @"note": @"Notification delivery and private method ABI still require device testing"});
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (handle) {
        AxsHeadsetBridgeCloudGetPID = (void (*)(dispatch_queue_t, void (^)(pid_t)))dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
        AxsHeadsetBridgeCloudGetPlaying = (void (*)(dispatch_queue_t, void (^)(Boolean)))dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    }
    axs_headsetbridge_cloud_log(@"sb.api_availability", @{@"media_pid": @(AxsHeadsetBridgeCloudGetPID != NULL), @"media_playing": @(AxsHeadsetBridgeCloudGetPlaying != NULL), @"app_internal_playback_experiment": @YES, @"bluetooth_manager": @(objc_getClass("BluetoothManager") != Nil)});
    uint32_t leaseRegistration = notify_register_check(AxsHeadsetBridgeCloudLease, &AxsHeadsetBridgeCloudLeaseWriter);
    axs_headsetbridge_cloud_revokeLease();
    axs_headsetbridge_cloud_log(@"sb.lease_writer", @{@"registration": @(leaseRegistration)});
    uint32_t requestResult = notify_register_check(AxsHeadsetBridgeCloudRequest, &AxsHeadsetBridgeCloudRequestToken);
    static int ackToken;
    uint32_t ackResult = notify_register_dispatch(AxsHeadsetBridgeCloudAck, &ackToken, dispatch_get_main_queue(), ^(int token) {
        if (!AxsHeadsetBridgeCloudBusy) return;
        uint64_t state = 0;
        uint32_t result = notify_get_state(token, &state);
        uint32_t generation = (uint32_t)(state >> 32);
        uint32_t low = (uint32_t)state;
        pid_t pid = (pid_t)(low & 0x7fffffffU);
        BOOL bluetooth = (low & 0x80000000U) != 0;
        if (result != NOTIFY_STATUS_OK || !AxsHeadsetBridgeCloudChallengePending || generation != AxsHeadsetBridgeCloudChallenge || pid <= 0) {
            axs_headsetbridge_cloud_log(@"sb.ack_rejected", @{@"notify_result": @(result), @"ack_generation": @(generation)});
            return;
        }
        AxsHeadsetBridgeCloudMusicPID = pid;
        AxsHeadsetBridgeCloudChallengePending = NO;
        axs_headsetbridge_cloud_log(@"sb.music_ack", @{@"generation": @(AxsHeadsetBridgeCloudGeneration), @"challenge": @(generation), @"reported_music_pid": @(pid), @"reported_bluetooth_route": @(bluetooth), @"note": @"Diagnostic hint, not authenticated process identity"});
    });
    axs_headsetbridge_cloud_log(@"sb.ipc_observers", @{@"request_result": @(requestResult), @"ack_result": @(ackResult)});
    AxsHeadsetBridgeCloudAddresses = axs_headsetbridge_cloud_addresses();
    AxsHeadsetBridgeCloudObservedEpoch = axs_headsetbridge_configurationEpoch();
    axs_headsetbridge_cloud_log(@"sb.baseline", @{@"audio_count": @(AxsHeadsetBridgeCloudAddresses.count)});
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:@"com.axs.headsetbridge.preferences-changed" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        (void)note;
        uint64_t epoch = axs_headsetbridge_configurationEpoch();
        if (AxsHeadsetBridgeCloudObservedEpoch != epoch) {
            AxsHeadsetBridgeCloudObservedEpoch = epoch;
            AxsHeadsetBridgeCloudAddresses = axs_headsetbridge_cloud_addresses();
        }
        if (AxsHeadsetBridgeCloudBusy && !axs_headsetbridge_bindingValid(@"cloud", AxsHeadsetBridgeCloudLeaseState)) {
            ++AxsHeadsetBridgeCloudGeneration;
            AxsHeadsetBridgeCloudBusy = NO;
        axs_headsetbridge_cloud_revokeLease();
            AxsHeadsetBridgeCloudChallengePending = NO;
            AxsHeadsetBridgeCloudMusicPID = 0;
            axs_headsetbridge_cloud_log(@"sb.session_cancelled", @{@"reason": @"disabled"});
        }
    }];
    for (NSString *name in @[@"BluetoothDeviceConnectSuccessNotification", @"BluetoothDeviceDisconnectSuccessNotification"]) {
        [center addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            (void)note;
            axs_headsetbridge_cloud_connectionsChanged();
        }];
    }
    [center addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        axs_headsetbridge_cloud_log(@"sb.local_route_changed", @{@"reason": note.userInfo[AVAudioSessionRouteChangeReasonKey] ?: @0, @"note": @"SpringBoard route is not proof of music app output"});
        axs_headsetbridge_cloud_connectionsChanged();
    }];
    // No permanent poll timer; baseline and connection notifications only.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        axs_headsetbridge_cloud_connectionsChanged();
    });
}
