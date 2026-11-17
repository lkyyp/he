#import "AxsHeadsetBridgeKuwoRuntime.h"
#import "AxsHeadsetBridgeKuwoConfig.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <notify.h>
#import <unistd.h>

static void axs_headsetbridge_kuwo_musicSnapshot(NSString *stage) {
    UIApplication *app = [UIApplication sharedApplication];
    NSMutableArray *outputs = [NSMutableArray array];
    for (AVAudioSessionPortDescription *port in [AVAudioSession sharedInstance].currentRoute.outputs) {
        [outputs addObject:port.portType ?: @"unknown"];
    }
    NSMutableArray *scenes = [NSMutableArray array];
    for (UIScene *scene in app.connectedScenes) {
        [scenes addObject:@{@"class": NSStringFromClass([scene class]), @"activation_state": @(scene.activationState)}];
    }
    NSDictionary *info = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
    axs_headsetbridge_kuwo_log(@"music.snapshot", @{
        @"stage": stage,
        @"application_state": @(app.applicationState),
        @"protected_data_available": @(app.protectedDataAvailable),
        @"scene_count": @(app.connectedScenes.count),
        @"scenes": scenes,
        @"main_thread": @([NSThread isMainThread]),
        @"application_class": NSStringFromClass([app class]),
        @"output_types": outputs,
        @"now_playing_key_count": @(info.count),
        @"play_command_enabled": @([MPRemoteCommandCenter sharedCommandCenter].playCommand.enabled),
        @"note": @"enabled does not prove a handler is installed; snapshot does not prove playback"
    });
}

void axs_headsetbridge_kuwo_startMusic(void) {
    // Earliest existing main-thread app entry; cannot run while the process is suspended.
    axs_headsetbridge_kuwo_startBackground();
    axs_headsetbridge_kuwo_log(@"music.injected", @{
        @"version": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
        @"build": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
        @"log_path": axs_headsetbridge_kuwo_logPath()
    });
    axs_headsetbridge_kuwo_startPlayback();
    axs_headsetbridge_kuwo_log(@"config.app_gate", @{@"enabled_for_engine": @([[AxsHeadsetBridgeKuwoConfig axs_headsetbridge_kuwo_shared] axs_headsetbridge_kuwo_isEnabled])});
    // Playback trial reuses uploaded metadata; no expensive inventory on cold launch.
    static int token;
    static int ackToken;
    uint32_t ackRegistration = notify_register_check(AxsHeadsetBridgeKuwoAck, &ackToken);
    static dispatch_queue_t receiverQueue;
    receiverQueue = dispatch_queue_create("com.axs.headsetbridge.kuwo.receive", DISPATCH_QUEUE_SERIAL);
    uint32_t result = notify_register_dispatch(AxsHeadsetBridgeKuwoRequest, &token, receiverQueue, ^(int t) {
        // No UIApplication/AVAudioSession/player access on this queue.
        NSTimeInterval received = [NSProcessInfo processInfo].systemUptime;
        uint64_t requestState = 0;
        uint32_t readResult = notify_get_state(t, &requestState);
        axs_headsetbridge_kuwo_log(@"kuwo.request_received_queue", @{@"request_session": @((uint32_t)(requestState >> 32)), @"challenge": @((uint32_t)requestState), @"notify_result": @(readResult), @"received_uptime": @(received), @"main_thread": @([NSThread isMainThread])});
        if (readResult != NOTIFY_STATUS_OK || !(uint32_t)requestState) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSTimeInterval mainStarted = [NSProcessInfo processInfo].systemUptime;
            uint64_t currentRequest = 0;
            uint32_t currentResult = notify_get_state(t, &currentRequest);
            axs_headsetbridge_kuwo_log(@"kuwo.request_main_begin", @{@"request_session": @((uint32_t)(requestState >> 32)), @"challenge": @((uint32_t)requestState), @"received_uptime": @(received), @"main_started_uptime": @(mainStarted), @"handoff_delay_ms": @((mainStarted - received) * 1000.0), @"request_still_current": @(currentResult == NOTIFY_STATUS_OK && currentRequest == requestState), @"current_session":@((uint32_t)(currentRequest >> 32)), @"current_challenge":@((uint32_t)currentRequest), @"control_revision":@1});
            // Challenge is ACK correlation, not a replacement of this connection's lease.
            if (currentResult != NOTIFY_STATUS_OK || !(uint32_t)currentRequest || !(uint32_t)(requestState >> 32) || (uint32_t)(currentRequest >> 32) != (uint32_t)(requestState >> 32)) {
                axs_headsetbridge_kuwo_log(@"kuwo.request_dropped", @{@"reason": @"request_superseded_before_main", @"request_session": @((uint32_t)(requestState >> 32)), @"challenge": @((uint32_t)requestState)}); return;
            }
            if (![[AxsHeadsetBridgeKuwoConfig axs_headsetbridge_kuwo_shared] axs_headsetbridge_kuwo_isEnabled]) {
                axs_headsetbridge_kuwo_log(@"kuwo.request_gate_rejected", @{@"reason":@"disabled_target_or_configuration_unavailable", @"request_session":@((uint32_t)(requestState >> 32)), @"challenge":@((uint32_t)requestState)}); return;
            }
            axs_headsetbridge_kuwo_reconcileBackground(@"request_main_before_preflight");
            axs_headsetbridge_kuwo_musicSnapshot(@"request_received");
            BOOL bluetooth = NO;
            for (AVAudioSessionPortDescription *port in [AVAudioSession sharedInstance].currentRoute.outputs) {
                if ([port.portType isEqual:AVAudioSessionPortBluetoothA2DP] || [port.portType isEqual:AVAudioSessionPortBluetoothHFP] || [port.portType isEqual:AVAudioSessionPortBluetoothLE]) bluetooth = YES;
            }
            uint64_t playbackRequest = 0;
            if (notify_get_state(t, &playbackRequest) != NOTIFY_STATUS_OK || !(uint32_t)playbackRequest || (uint32_t)(playbackRequest >> 32) != (uint32_t)(requestState >> 32)) return;
            uint32_t low = ((uint32_t)getpid() & 0x7fffffffU) | (bluetooth ? 0x80000000U : 0);
            uint64_t state = ((uint64_t)(uint32_t)playbackRequest << 32) | low;
            uint32_t setResult = ackRegistration == NOTIFY_STATUS_OK ? notify_set_state(ackToken, state) : NOTIFY_STATUS_FAILED;
            uint32_t posted = setResult == NOTIFY_STATUS_OK ? notify_post(AxsHeadsetBridgeKuwoAck) : setResult;
            axs_headsetbridge_kuwo_log(@"music.ack_sent", @{@"notify_result": @(posted), @"challenge": @((uint32_t)playbackRequest), @"request_session": @((uint32_t)(playbackRequest >> 32)), @"bluetooth": @(bluetooth), @"control_revision":@1});
            if (posted == NOTIFY_STATUS_OK) axs_headsetbridge_kuwo_tryPlayback(playbackRequest);
        });
    });
    axs_headsetbridge_kuwo_log(@"music.request_observer", @{@"notify_result": @(result)});
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    NSArray *names = @[
        UIApplicationDidFinishLaunchingNotification,
        UIApplicationWillEnterForegroundNotification,
        UIApplicationDidEnterBackgroundNotification,
        UIApplicationDidBecomeActiveNotification,
        UIApplicationWillResignActiveNotification,
        UIApplicationProtectedDataDidBecomeAvailable,
        UIApplicationProtectedDataWillBecomeUnavailable,
        UISceneDidActivateNotification,
        UISceneWillDeactivateNotification,
        UISceneDidEnterBackgroundNotification,
        UISceneWillEnterForegroundNotification
    ];
    for (NSString *name in names) {
        [center addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            if (![[AxsHeadsetBridgeKuwoConfig axs_headsetbridge_kuwo_shared] axs_headsetbridge_kuwo_isEnabled]) return;
            axs_headsetbridge_kuwo_musicSnapshot(note.name);
        }];
    }
    for (NSNumber *seconds in @[@1, @3, @8, @15]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BOOL enabledForEngine=[[AxsHeadsetBridgeKuwoConfig axs_headsetbridge_kuwo_shared] axs_headsetbridge_kuwo_isEnabled];
            axs_headsetbridge_kuwo_log(@"config.app_timer_gate", @{@"second":seconds, @"enabled_for_engine":@(enabledForEngine)});
            if (!enabledForEngine) return;
            axs_headsetbridge_kuwo_musicSnapshot([NSString stringWithFormat:@"timer_%@s", seconds]);
        });
    }
}

void axs_headsetbridge_kuwo_signalMusic(void) {
    if (![[AxsHeadsetBridgeKuwoConfig axs_headsetbridge_kuwo_shared] axs_headsetbridge_kuwo_isEnabled]) return;
    axs_headsetbridge_kuwo_log(@"music.now_playing_updated", @{});
}
