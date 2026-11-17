#import "AxsHeadsetBridgeCloudRuntime.h"
#import "AxsHeadsetBridgeCloudConfig.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import <string.h>

static int AxsHeadsetBridgeCloudLeaseToken = -1;
static int AxsHeadsetBridgeCloudPlaybackRequestToken = -1;
static BOOL AxsHeadsetBridgeCloudPlaybackIPCReady;
static uint32_t AxsHeadsetBridgeCloudHandledSession;
static int AxsHeadsetBridgeCloudConsumedToken = -1;
static BOOL AxsHeadsetBridgeCloudInFlight;

static BOOL axs_headsetbridge_cloud_signature(id object, NSString *name, char result) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return NO;
    NSMethodSignature *sig = [object methodSignatureForSelector:selector];
    return sig && sig.numberOfArguments == 2 && strlen(sig.methodReturnType) == 1 && sig.methodReturnType[0] == result;
}

static id axs_headsetbridge_cloud_getObject(id object, NSString *name) {
    if (!axs_headsetbridge_cloud_signature(object, name, '@')) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name));
}

static BOOL axs_headsetbridge_cloud_getBool(id object, NSString *name, BOOL *known) {
    *known = axs_headsetbridge_cloud_signature(object, name, 'B');
    return *known ? ((BOOL (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name)) : NO;
}

static BOOL axs_headsetbridge_cloud_hasBluetooth(void) {
    for (AVAudioSessionPortDescription *port in [AVAudioSession sharedInstance].currentRoute.outputs) {
        // Only A2DP or Bluetooth LE. Do not activate an audio session or select a route.
        if ([port.portType isEqual:AVAudioSessionPortBluetoothA2DP] || [port.portType isEqual:AVAudioSessionPortBluetoothLE]) return YES;
    }
    return NO;
}

static uint64_t axs_headsetbridge_cloud_liveLease(uint64_t requestState) {
    if (!AxsHeadsetBridgeCloudPlaybackIPCReady || ![[AxsHeadsetBridgeCloudConfig axs_headsetbridge_cloud_shared] axs_headsetbridge_cloud_isEnabled]) return 0;
    uint64_t request = 0, lease = 0;
    if (notify_get_state(AxsHeadsetBridgeCloudPlaybackRequestToken, &request) != NOTIFY_STATUS_OK || request != requestState || (uint32_t)requestState == 0) return 0;
    if (notify_get_state(AxsHeadsetBridgeCloudLeaseToken, &lease) != NOTIFY_STATUS_OK) return 0;
    if (!axs_headsetbridge_bindingValid(@"cloud", lease)) return 0;
    uint32_t nonce = (uint32_t)(lease >> 32), expires = (uint32_t)lease;
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    if (!nonce || nonce != (uint32_t)(requestState >> 32) || expires <= now || expires - now > 25.0) return 0;
    uint64_t consumed = 0;
    if (notify_get_state(AxsHeadsetBridgeCloudConsumedToken, &consumed) != NOTIFY_STATUS_OK || consumed == nonce) return 0;
    return lease;
}

static BOOL axs_headsetbridge_cloud_consumeLease(uint64_t expected) {
    uint64_t current = 0;
    if (notify_get_state(AxsHeadsetBridgeCloudLeaseToken, &current) != NOTIFY_STATUS_OK || current != expected) return NO;
    // Only SpringBoard writes the lease; consuming an old session cannot clear a new lease.
    // Session markers remain non-authenticated and are not atomic authorization.
    return notify_set_state(AxsHeadsetBridgeCloudConsumedToken, (uint32_t)(expected >> 32)) == NOTIFY_STATUS_OK;
}

void axs_headsetbridge_cloud_startPlayback(void) {
    uint32_t a = notify_register_check(AxsHeadsetBridgeCloudLease, &AxsHeadsetBridgeCloudLeaseToken);
    uint32_t b = notify_register_check(AxsHeadsetBridgeCloudRequest, &AxsHeadsetBridgeCloudPlaybackRequestToken);
    uint32_t c = notify_register_check(AxsHeadsetBridgeCloudConsumed, &AxsHeadsetBridgeCloudConsumedToken);
    AxsHeadsetBridgeCloudPlaybackIPCReady = a == NOTIFY_STATUS_OK && b == NOTIFY_STATUS_OK && c == NOTIFY_STATUS_OK;
    axs_headsetbridge_cloud_log(@"music.playback_module", @{@"lease_registration": @(a), @"request_registration": @(b), @"mode": @"one playCurrentSong attempt per live lease; regular songlist only"});
}

void axs_headsetbridge_cloud_tryPlayback(uint64_t requestState) {
    uint32_t challenge = (uint32_t)requestState;
    if (![NSThread isMainThread] || AxsHeadsetBridgeCloudInFlight) return;
    AxsHeadsetBridgeCloudInFlight = YES;
    @try {
    uint64_t lease = axs_headsetbridge_cloud_liveLease(requestState);
    if (!lease) { axs_headsetbridge_cloud_log(@"music.play_skip", @{@"reason": @"no_live_lease", @"challenge": @(challenge)}); return; }
    uint32_t session = (uint32_t)(lease >> 32);
    if (AxsHeadsetBridgeCloudHandledSession == session) return;
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *version = info[@"CFBundleShortVersionString"];
    NSString *build = info[@"CFBundleVersion"];
    // Exact version/build pairs only. The 9.6.25 interface metadata was supplied by the user.
    BOOL supportedPair = ([version isEqual:@"9.0.08"] && [build isEqual:@"4702"]) ||
                         ([version isEqual:@"9.6.25"] && [build isEqual:@"7644"]);
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqual:@"com.netease.cloudmusic"] || !supportedPair) {
        axs_headsetbridge_cloud_log(@"music.play_skip", @{@"reason": @"unsupported_app_version", @"version": version ?: @"unknown", @"build": build ?: @"unknown"}); return;
    }
    if (!axs_headsetbridge_cloud_hasBluetooth()) { axs_headsetbridge_cloud_log(@"music.play_skip", @{@"reason": @"no_bluetooth_media_route"}); return; }
    @try {
        Class manager = objc_getClass("NMPlayerManager");
        BOOL initializedKnown = NO;
        BOOL initialized = axs_headsetbridge_cloud_getBool(manager, @"initialized", &initializedKnown);
        if (!initializedKnown || !initialized) {
            axs_headsetbridge_cloud_log(@"music.player_not_ready", @{@"reason": @"manager_not_initialized", @"known": @(initializedKnown)}); return;
        }
        id controller = axs_headsetbridge_cloud_getObject(manager, @"currentPlayerController");
        Class songlistClass = objc_getClass("NMSonglistPlayerController");
        if (!controller || !songlistClass || ![controller isKindOfClass:songlistClass]) {
            axs_headsetbridge_cloud_log(@"music.player_not_ready", @{@"reason": @"not_regular_songlist_controller", @"controller_class": controller ? NSStringFromClass([controller class]) : @"nil"}); return;
        }
        BOOL known = NO;
        BOOL playing = axs_headsetbridge_cloud_getBool(controller, @"isPlayingState", &known);
        id player = axs_headsetbridge_cloud_getObject(controller, @"player");
        axs_headsetbridge_cloud_log(@"music.player_preflight", @{@"session": @(session), @"challenge": @(challenge), @"controller_class": NSStringFromClass([controller class]), @"player_class": player ? NSStringFromClass([player class]) : @"nil", @"playing_known": @(known), @"playing": @(playing)});
        if (!known) return;
        if (playing) { AxsHeadsetBridgeCloudHandledSession = session; axs_headsetbridge_cloud_consumeLease(lease); return; }
        // Do not construct players, pass guessed enums, switch modes or manufacture a queue.
        Class single = objc_getClass("NMPlayer"), multi = objc_getClass("NMMultiPlayer");
        if (!player || !((single && [player isKindOfClass:single]) || (multi && [player isKindOfClass:multi]))) {
            axs_headsetbridge_cloud_log(@"music.player_not_ready", @{@"reason": @"no_existing_song_player"}); return;
        }
        if (!axs_headsetbridge_cloud_signature(controller, @"playCurrentSong", 'v')) {
            axs_headsetbridge_cloud_log(@"music.play_skip", @{@"reason": @"signature_mismatch"}); return;
        }
        if (axs_headsetbridge_cloud_liveLease(requestState) != lease || !axs_headsetbridge_cloud_hasBluetooth()) return;
        id current = axs_headsetbridge_cloud_getObject(manager, @"currentPlayerController");
        if (current != controller || axs_headsetbridge_cloud_getObject(controller, @"player") != player) return;
        if (axs_headsetbridge_cloud_getBool(controller, @"isPlayingState", &known) || !known) { AxsHeadsetBridgeCloudHandledSession = session; axs_headsetbridge_cloud_consumeLease(lease); return; }
        if (!axs_headsetbridge_cloud_consumeLease(lease)) {
            axs_headsetbridge_cloud_log(@"music.play_skip", @{@"reason": @"lease_consume_failed"}); return;
        }
        axs_headsetbridge_cloud_log(@"music.play_prepared", @{@"session": @(session), @"challenge": @(challenge), @"selector": @"playCurrentSong", @"note": @"Experimental internal call, not evidence of playback success"});
        uint64_t finalRequest = 0, finalLease = 0;
        if (notify_get_state(AxsHeadsetBridgeCloudPlaybackRequestToken, &finalRequest) != NOTIFY_STATUS_OK || finalRequest != requestState || notify_get_state(AxsHeadsetBridgeCloudLeaseToken, &finalLease) != NOTIFY_STATUS_OK || finalLease != lease) return;
        if (!axs_headsetbridge_bindingValid(@"cloud", lease) || !axs_headsetbridge_cloud_hasBluetooth() || (uint32_t)lease <= [NSProcessInfo processInfo].systemUptime) return;
        AxsHeadsetBridgeCloudHandledSession = session; // Mark BEFORE invoking; no retry after an exception or manual pause.
        ((void (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"playCurrentSong"));
        axs_headsetbridge_cloud_log(@"music.play_returned", @{@"session": @(session), @"challenge": @(challenge), @"note": @"Call returned normally; not proof of audio output"});
        for (NSNumber *second in @[@1, @3, @6]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(second.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try {
                    if (!axs_headsetbridge_bindingValid(@"cloud", lease) || (uint32_t)lease <= [NSProcessInfo processInfo].systemUptime || !axs_headsetbridge_cloud_hasBluetooth()) return;
                    id latest = axs_headsetbridge_cloud_getObject(manager, @"currentPlayerController");
                    BOOL stateKnown = NO;
                    BOOL state = axs_headsetbridge_cloud_getBool(latest, @"isPlayingState", &stateKnown);
                    axs_headsetbridge_cloud_log(@"music.play_verify", @{@"session": @(session), @"second": second, @"same_controller": @(latest == controller), @"playing_known": @(stateKnown), @"playing": @(state), @"bluetooth_route": @(axs_headsetbridge_cloud_hasBluetooth()), @"note": @"App-reported state only; verify system state and audible output"});
                } @catch (NSException *e) { axs_headsetbridge_cloud_log(@"music.verify_exception", @{@"name": e.name}); }
            });
        }
    } @catch (NSException *exception) {
        axs_headsetbridge_cloud_consumeLease(lease);
        AxsHeadsetBridgeCloudHandledSession = session;
        axs_headsetbridge_cloud_log(@"music.play_exception", @{@"name": exception.name, @"session": @(session)});
    }
    } @finally { AxsHeadsetBridgeCloudInFlight = NO; }
}
