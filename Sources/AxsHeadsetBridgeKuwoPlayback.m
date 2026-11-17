#import "AxsHeadsetBridgeKuwoRuntime.h"
#import "AxsHeadsetBridgeKuwoConfig.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import <string.h>
#import "AxsHeadsetBridgeKuwoDiagnostics.h"

static int AxsHeadsetBridgeKuwoLeaseToken = -1;
static int AxsHeadsetBridgeKuwoPlaybackRequestToken = -1;
static BOOL AxsHeadsetBridgeKuwoPlaybackIPCReady;
static uint32_t AxsHeadsetBridgeKuwoHandledSession;
static int AxsHeadsetBridgeKuwoConsumedToken = -1;
static BOOL AxsHeadsetBridgeKuwoInFlight;

static BOOL axs_headsetbridge_kuwo_signature(id object, NSString *name, char result) {
    SEL sel = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:sel]) return NO;
    NSMethodSignature *sig = [object methodSignatureForSelector:sel];
    return sig && sig.numberOfArguments == 2 && strlen(sig.methodReturnType) == 1 && sig.methodReturnType[0] == result;
}
static id axs_headsetbridge_kuwo_getObject(id object, NSString *name) {
    return axs_headsetbridge_kuwo_signature(object, name, '@') ? ((id (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name)) : nil;
}
static BOOL axs_headsetbridge_kuwo_getBool(id object, NSString *name, BOOL *known) {
    *known = axs_headsetbridge_kuwo_signature(object, name, 'B');
    return *known ? ((BOOL (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name)) : NO;
}
static BOOL axs_headsetbridge_kuwo_hasBluetooth(void) {
    for (AVAudioSessionPortDescription *port in [AVAudioSession sharedInstance].currentRoute.outputs) {
        if ([port.portType isEqual:AVAudioSessionPortBluetoothA2DP] || [port.portType isEqual:AVAudioSessionPortBluetoothLE]) return YES;
    }
    return NO;
}
static uint64_t axs_headsetbridge_kuwo_liveLease(uint64_t requestState) {
    if (!AxsHeadsetBridgeKuwoPlaybackIPCReady || ![[AxsHeadsetBridgeKuwoConfig axs_headsetbridge_kuwo_shared] axs_headsetbridge_kuwo_isEnabled]) return 0;
    uint64_t request = 0, lease = 0;
    if (notify_get_state(AxsHeadsetBridgeKuwoPlaybackRequestToken, &request) != NOTIFY_STATUS_OK || !(uint32_t)request || !(uint32_t)requestState || !(uint32_t)(requestState >> 32) || (uint32_t)(request >> 32) != (uint32_t)(requestState >> 32)) return 0;
    if (notify_get_state(AxsHeadsetBridgeKuwoLeaseToken, &lease) != NOTIFY_STATUS_OK) return 0;
    if (!axs_headsetbridge_bindingValid(@"kuwo", lease)) return 0;
    uint32_t nonce = (uint32_t)(lease >> 32), expires = (uint32_t)lease;
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    if (!nonce || nonce != (uint32_t)(requestState >> 32) || expires <= now || expires - now > 25.0) return 0;
    uint64_t consumed = 0;
    if (notify_get_state(AxsHeadsetBridgeKuwoConsumedToken, &consumed) != NOTIFY_STATUS_OK || consumed == nonce) return 0;
    return lease;
}
static BOOL axs_headsetbridge_kuwo_consumeLease(uint64_t expected, BOOL forPlayback) {
    uint64_t lease = 0;
    if (notify_get_state(AxsHeadsetBridgeKuwoLeaseToken, &lease) != NOTIFY_STATUS_OK || lease != expected) return NO;
    // App marks its own consumed session; only SpringBoard writes the lease.
    // Still not authenticated or atomic CAS authorization.
    BOOL consumedOK = notify_set_state(AxsHeadsetBridgeKuwoConsumedToken, (uint32_t)(expected >> 32)) == NOTIFY_STATUS_OK;
    if (consumedOK) axs_headsetbridge_kuwo_backgroundConsumed(expected, forPlayback);
    return consumedOK;
}
static void axs_headsetbridge_kuwo_notReady(NSString *reason, uint32_t session) {
    axs_headsetbridge_kuwo_log(@"kuwo.player_not_ready", @{@"reason":reason, @"session":@(session)});
}

void axs_headsetbridge_kuwo_startPlayback(void) {
    uint32_t a = notify_register_check(AxsHeadsetBridgeKuwoLease, &AxsHeadsetBridgeKuwoLeaseToken);
    uint32_t b = notify_register_check(AxsHeadsetBridgeKuwoRequest, &AxsHeadsetBridgeKuwoPlaybackRequestToken);
    uint32_t c = notify_register_check(AxsHeadsetBridgeKuwoConsumed, &AxsHeadsetBridgeKuwoConsumedToken);
    AxsHeadsetBridgeKuwoPlaybackIPCReady = a == NOTIFY_STATUS_OK && b == NOTIFY_STATUS_OK && c == NOTIFY_STATUS_OK;
    axs_headsetbridge_kuwo_log(@"kuwo.playback_module", @{@"lease_registration":@(a), @"request_registration":@(b), @"consumed_registration":@(c), @"selector":@"MediaPlayerManager -play", @"note":@"one guarded BOOL-returning play attempt per connection; not a toggle"});
}

void axs_headsetbridge_kuwo_tryPlayback(uint64_t requestState) {
    if (![NSThread isMainThread] || AxsHeadsetBridgeKuwoInFlight) return;
    NSTimeInterval diagnosticStarted=axs_headsetbridge_kuwo_profileClockSeconds();
    BOOL diagnosticPlayCalled=NO;
    NSTimeInterval diagnosticPlayStarted=0;
    NSTimeInterval diagnosticPlayReturned=0;
    AxsHeadsetBridgeKuwoInFlight = YES;
    @try {
    uint32_t challenge = (uint32_t)requestState;
    uint64_t lease = axs_headsetbridge_kuwo_liveLease(requestState);
    if (!lease) { axs_headsetbridge_kuwo_log(@"kuwo.play_skip", @{@"reason":@"no_live_lease", @"challenge":@(challenge)}); return; }
    uint32_t session = (uint32_t)(lease >> 32);
    if (AxsHeadsetBridgeKuwoHandledSession == session) return;
    NSBundle *bundle = [NSBundle mainBundle];
    if (![bundle.bundleIdentifier isEqual:@"com.yeelion.kwplayer"] || ![[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:@"12.0.0"] || ![[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:@"11418"]) {
        axs_headsetbridge_kuwo_log(@"kuwo.play_skip", @{@"reason":@"unsupported_app_version"}); return;
    }
    if (!axs_headsetbridge_kuwo_hasBluetooth()) { axs_headsetbridge_kuwo_notReady(@"no_bluetooth_media_route", session); return; }
    @try {
        Class managerClass = objc_getClass("MediaPlayerManager");
        Class centerClass = objc_getClass("KWPlayControlCenter");
        id manager = axs_headsetbridge_kuwo_getObject(managerClass, @"playerInstance");
        id center = axs_headsetbridge_kuwo_getObject(centerClass, @"shareInstance");
        if (!managerClass || !manager || ![manager isKindOfClass:managerClass] || !centerClass || !center || ![center isKindOfClass:centerClass]) {
            axs_headsetbridge_kuwo_notReady(@"no_expected_manager_or_control_center", session); return;
        }
        BOOL known = NO;
        BOOL playing = axs_headsetbridge_kuwo_getBool(manager, @"isPlaying", &known);
        if (!known) { axs_headsetbridge_kuwo_notReady(@"playing_signature_mismatch", session); return; }
        if (playing) {
            AxsHeadsetBridgeKuwoHandledSession = session;
            axs_headsetbridge_kuwo_consumeLease(lease, NO);
            axs_headsetbridge_kuwo_log(@"kuwo.already_playing", @{@"session":@(session)}); return;
        }
        BOOL songKnown = NO, adKnown = NO;
        BOOL song = axs_headsetbridge_kuwo_getBool(center, @"isMediaPlayerManagerSong", &songKnown);
        BOOL ad = axs_headsetbridge_kuwo_getBool(center, @"isPlayAD", &adKnown);
        id player = axs_headsetbridge_kuwo_getObject(manager, @"currentPlayer");
        id selectedPlayer = axs_headsetbridge_kuwo_getObject(center, @"currentPlayer");
        id item = axs_headsetbridge_kuwo_getObject(manager, @"currentMediaItemInfo");
        Class expectedPlayer = objc_getClass("KWMediaPlayer");
        Class expectedItem = objc_getClass("MediaItemInfo");
        axs_headsetbridge_kuwo_log(@"kuwo.player_preflight", @{@"session":@(session), @"challenge":@(challenge), @"manager_class":NSStringFromClass([manager class]), @"player_class":player ? NSStringFromClass([player class]) : @"nil", @"item_class":item ? NSStringFromClass([item class]) : @"nil", @"same_selected_player":@(selectedPlayer == player), @"song_mode_known":@(songKnown), @"song_mode":@(song), @"ad_known":@(adKnown), @"ad":@(ad), @"playing":@(playing)});
        if (!songKnown || !adKnown || !song || ad) { axs_headsetbridge_kuwo_notReady(@"not_confirmed_normal_song_mode", session); return; }
        if (!expectedPlayer || !player || ![player isKindOfClass:expectedPlayer] || selectedPlayer != player) { axs_headsetbridge_kuwo_notReady(@"no_matching_current_song_player", session); return; }
        if (!expectedItem || !item || ![item isKindOfClass:expectedItem]) { axs_headsetbridge_kuwo_notReady(@"no_existing_media_item", session); return; }
        // Do not construct a player/queue, change modes, select an item, or guess quality enums.
        if (!axs_headsetbridge_kuwo_signature(manager, @"play", 'B')) { axs_headsetbridge_kuwo_notReady(@"play_signature_mismatch", session); return; }
        if (axs_headsetbridge_kuwo_getObject(managerClass, @"playerInstance") != manager || axs_headsetbridge_kuwo_getObject(manager, @"currentPlayer") != player || axs_headsetbridge_kuwo_getObject(manager, @"currentMediaItemInfo") != item || axs_headsetbridge_kuwo_getObject(center, @"currentPlayer") != player) { axs_headsetbridge_kuwo_notReady(@"player_or_item_changed", session); return; }
        song = axs_headsetbridge_kuwo_getBool(center, @"isMediaPlayerManagerSong", &songKnown);
        ad = axs_headsetbridge_kuwo_getBool(center, @"isPlayAD", &adKnown);
        if (!songKnown || !adKnown || !song || ad) return;
        if (axs_headsetbridge_kuwo_getBool(manager, @"isPlaying", &known) || !known) {
            AxsHeadsetBridgeKuwoHandledSession = session; axs_headsetbridge_kuwo_consumeLease(lease, NO); return;
        }
        if (!axs_headsetbridge_kuwo_hasBluetooth() || axs_headsetbridge_kuwo_liveLease(requestState) != lease) return;
        if (AxsHeadsetBridgeKuwoHandledSession == session) return;
        if (!axs_headsetbridge_kuwo_consumeLease(lease, YES)) { axs_headsetbridge_kuwo_notReady(@"lease_consume_failed", session); return; }
        axs_headsetbridge_kuwo_log(@"kuwo.play_prepared", @{@"session":@(session), @"challenge":@(challenge), @"selector":@"play", @"owner":@"MediaPlayerManager"});
        uint64_t finalRequest = 0, finalLease = 0;
        if (notify_get_state(AxsHeadsetBridgeKuwoPlaybackRequestToken, &finalRequest) != NOTIFY_STATUS_OK || !(uint32_t)finalRequest || (uint32_t)(finalRequest >> 32) != session || notify_get_state(AxsHeadsetBridgeKuwoLeaseToken, &finalLease) != NOTIFY_STATUS_OK || finalLease != lease || (uint32_t)lease <= [NSProcessInfo processInfo].systemUptime || ![[AxsHeadsetBridgeKuwoConfig axs_headsetbridge_kuwo_shared] axs_headsetbridge_kuwo_isEnabled] || !axs_headsetbridge_kuwo_hasBluetooth()) {
            axs_headsetbridge_kuwo_backgroundFinish(lease, @"final_preplay_check_failed"); return;
        }
        if (!axs_headsetbridge_bindingValid(@"kuwo", lease)) { axs_headsetbridge_kuwo_backgroundFinish(lease, @"selection_changed_before_play"); return; }
        AxsHeadsetBridgeKuwoHandledSession = session;
        diagnosticPlayCalled=YES;
        diagnosticPlayStarted=axs_headsetbridge_kuwo_profileClockSeconds();
        BOOL result = ((BOOL (*)(id, SEL))objc_msgSend)(manager, NSSelectorFromString(@"play"));
        diagnosticPlayReturned=axs_headsetbridge_kuwo_profileClockSeconds();
        axs_headsetbridge_kuwo_log(@"kuwo.play_return", @{@"session":@(session), @"returned":@(result), @"note":@"Method return is not evidence of audible output"});
        if (!result) axs_headsetbridge_kuwo_backgroundFinish(lease, @"play_returned_false");
        __weak id weakCenter = center;
        __weak id weakManager = manager;
        __weak id weakPlayer = player;
        __weak id weakItem = item;
        for (NSNumber *second in @[@1, @3, @6]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(second.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try {
                    NSTimeInterval diagnosticVerifyStarted=axs_headsetbridge_kuwo_profileClockSeconds();
                    uint64_t currentRequest = 0, currentLease = 0;
                    if (![[AxsHeadsetBridgeKuwoConfig axs_headsetbridge_kuwo_shared] axs_headsetbridge_kuwo_isEnabled] || !axs_headsetbridge_kuwo_hasBluetooth() || notify_get_state(AxsHeadsetBridgeKuwoPlaybackRequestToken, &currentRequest) != NOTIFY_STATUS_OK || (uint32_t)(currentRequest >> 32) != session || notify_get_state(AxsHeadsetBridgeKuwoLeaseToken, &currentLease) != NOTIFY_STATUS_OK || currentLease != lease || (uint32_t)lease <= [NSProcessInfo processInfo].systemUptime) return;
                    if (!axs_headsetbridge_bindingValid(@"kuwo", lease)) { axs_headsetbridge_kuwo_backgroundFinish(lease, @"selection_changed_during_verify"); return; }
                    id currentManager = weakManager;
                    id originalPlayer = weakPlayer;
                    id originalItem = weakItem;
                    if (!currentManager || !originalPlayer || !originalItem) return;
                    id currentPlayer = axs_headsetbridge_kuwo_getObject(currentManager, @"currentPlayer");
                    BOOL stateKnown = NO;
                    BOOL state = axs_headsetbridge_kuwo_getBool(currentManager, @"isPlaying", &stateKnown);
                    id currentItem = axs_headsetbridge_kuwo_getObject(currentManager, @"currentMediaItemInfo");
                    if (currentPlayer != originalPlayer || currentItem != originalItem || !stateKnown) axs_headsetbridge_kuwo_backgroundFinish(lease, @"verification_context_changed");
                    else if (state) axs_headsetbridge_kuwo_backgroundFinish(lease, @"app_reported_playing");
                    axs_headsetbridge_kuwo_log(@"kuwo.play_verify", @{@"session":@(session), @"second":second, @"same_player":@(currentPlayer == originalPlayer), @"same_item":@(currentItem == originalItem), @"playing_known":@(stateKnown), @"playing":@(state), @"bluetooth_route":@(axs_headsetbridge_kuwo_hasBluetooth()), @"note":@"Read-only app state; compare system PID/playing and actual sound"});
                    double originalVerifyFinished=axs_headsetbridge_kuwo_profileClockSeconds();
                    axs_headsetbridge_kuwo_profileReport(@"verify_after_original_checks",requestState);
                    if (axs_headsetbridge_kuwo_profileBegin()) {
                        axs_headsetbridge_kuwo_log(@"kuwo.verify_timing",@{@"session":@(session),@"second":second,@"entry_seconds_since_play_return":@(diagnosticVerifyStarted-diagnosticPlayReturned),@"original_verification_work_ms":@((originalVerifyFinished-diagnosticVerifyStarted)*1000.0)});
                    }
                    if (currentPlayer==originalPlayer && currentItem==originalItem && stateKnown) axs_headsetbridge_kuwo_recordPlayerState(currentManager,originalPlayer,originalItem,weakCenter,lease,[NSString stringWithFormat:@"verify_%@s",second]);
                } @catch (NSException *e) { axs_headsetbridge_kuwo_log(@"kuwo.verify_exception", @{@"name":e.name}); }
            });
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            axs_headsetbridge_kuwo_recordPlayerState(weakManager,weakPlayer,weakItem,weakCenter,lease,@"post_play_next_main_turn");
        });
    } @catch (NSException *e) {
        axs_headsetbridge_kuwo_consumeLease(lease, NO);
        AxsHeadsetBridgeKuwoHandledSession = session;
        axs_headsetbridge_kuwo_log(@"kuwo.play_exception", @{@"name":e.name, @"session":@(session)});
    }
    } @finally {
        AxsHeadsetBridgeKuwoInFlight = NO;
        axs_headsetbridge_kuwo_reconcileBackground(@"playback_check_finished");
        @try {
            axs_headsetbridge_kuwo_profileReport(@"playback_check_finished",requestState);
            if (axs_headsetbridge_kuwo_profileBegin()) axs_headsetbridge_kuwo_log(@"kuwo.play_path_timing",@{@"request_session":@((uint32_t)(requestState>>32)),@"challenge":@((uint32_t)requestState),@"play_called":@(diagnosticPlayCalled),@"total_ms":@((axs_headsetbridge_kuwo_profileClockSeconds()-diagnosticStarted)*1000.0),@"entry_to_call_ms":@(diagnosticPlayCalled ? (diagnosticPlayStarted-diagnosticStarted)*1000.0 : -1.0),@"call_return_ms":@(diagnosticPlayReturned>0 ? (diagnosticPlayReturned-diagnosticPlayStarted)*1000.0 : -1.0)});
        } @catch(NSException *ignored) { (void)ignored; }
    }
}
