#import "AxsHeadsetBridgeCloudRuntime.h"
#import "AxsHeadsetBridgeCloudConfig.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <notify.h>
#import <unistd.h>

static void axs_headsetbridge_cloud_musicSnapshot(NSString *stage) {
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
    axs_headsetbridge_cloud_log(@"music.snapshot", @{
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

void axs_headsetbridge_cloud_startMusic(void) {
    axs_headsetbridge_cloud_log(@"music.injected", @{
        @"version": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
        @"build": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
        @"log_path": axs_headsetbridge_cloud_logPath()
    });
    axs_headsetbridge_cloud_startPlayback();
    axs_headsetbridge_cloud_log(@"config.app_gate", @{@"enabled_for_engine": @([[AxsHeadsetBridgeCloudConfig axs_headsetbridge_cloud_shared] axs_headsetbridge_cloud_isEnabled])});
    // Revision 3 reuses uploaded metadata; no expensive inventory on cold launch.
    static int token;
    static int ackToken;
    uint32_t ackRegistration = notify_register_check(AxsHeadsetBridgeCloudAck, &ackToken);
    uint32_t result = notify_register_dispatch(AxsHeadsetBridgeCloudRequest, &token, dispatch_get_main_queue(), ^(int t) {
        uint64_t observedRequest = 0;
        uint32_t observedRead = notify_get_state(t, &observedRequest);
        axs_headsetbridge_cloud_log(@"music.request_callback_entry", @{@"notify_result":@(observedRead), @"request_session":@((uint32_t)(observedRequest >> 32)), @"challenge":@((uint32_t)observedRequest)});
        if (![[AxsHeadsetBridgeCloudConfig axs_headsetbridge_cloud_shared] axs_headsetbridge_cloud_isEnabled]) {
            axs_headsetbridge_cloud_log(@"music.request_gate_rejected", @{@"reason":@"disabled_target_or_configuration_unavailable"}); return;
        }
        axs_headsetbridge_cloud_musicSnapshot(@"request_received");
        uint64_t generation = 0;
        uint32_t readResult = notify_get_state(t, &generation);
        BOOL bluetooth = NO;
        for (AVAudioSessionPortDescription *port in [AVAudioSession sharedInstance].currentRoute.outputs) {
            if ([port.portType isEqual:AVAudioSessionPortBluetoothA2DP] || [port.portType isEqual:AVAudioSessionPortBluetoothHFP] || [port.portType isEqual:AVAudioSessionPortBluetoothLE]) bluetooth = YES;
        }
        uint32_t low = ((uint32_t)getpid() & 0x7fffffffU) | (bluetooth ? 0x80000000U : 0);
        uint64_t state = ((uint64_t)(uint32_t)generation << 32) | low;
        uint32_t setResult = (readResult == NOTIFY_STATUS_OK && ackRegistration == NOTIFY_STATUS_OK) ? notify_set_state(ackToken, state) : NOTIFY_STATUS_FAILED;
        uint32_t posted = setResult == NOTIFY_STATUS_OK ? notify_post(AxsHeadsetBridgeCloudAck) : setResult;
        axs_headsetbridge_cloud_log(@"music.ack_sent", @{@"notify_result": @(posted), @"challenge": @((uint32_t)generation), @"request_session": @((uint32_t)(generation >> 32)), @"bluetooth": @(bluetooth)});
        if (posted == NOTIFY_STATUS_OK) axs_headsetbridge_cloud_tryPlayback(generation);
    });
    axs_headsetbridge_cloud_log(@"music.request_observer", @{@"notify_result": @(result)});
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
            if (![[AxsHeadsetBridgeCloudConfig axs_headsetbridge_cloud_shared] axs_headsetbridge_cloud_isEnabled]) return;
            axs_headsetbridge_cloud_musicSnapshot(note.name);
        }];
    }
    for (NSNumber *seconds in @[@1, @3, @8, @15]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BOOL enabledForEngine=[[AxsHeadsetBridgeCloudConfig axs_headsetbridge_cloud_shared] axs_headsetbridge_cloud_isEnabled];
            axs_headsetbridge_cloud_log(@"config.app_timer_gate", @{@"second":seconds, @"enabled_for_engine":@(enabledForEngine)});
            if (!enabledForEngine) return;
            axs_headsetbridge_cloud_musicSnapshot([NSString stringWithFormat:@"timer_%@s", seconds]);
        });
    }
}

void axs_headsetbridge_cloud_signalMusic(void) {
    if (![[AxsHeadsetBridgeCloudConfig axs_headsetbridge_cloud_shared] axs_headsetbridge_cloud_isEnabled]) return;
    axs_headsetbridge_cloud_log(@"music.now_playing_updated", @{});
}
