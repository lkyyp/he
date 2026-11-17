#import <Foundation/Foundation.h>
#import "AxsHeadsetBridgeConfig.h"
#import "AxsHeadsetBridgeCloudRuntime.h"
#import "AxsHeadsetBridgeKuwoRuntime.h"
#import "AxsHeadsetBridgeKuwoDiagnostics.h"
#import "AxsHeadsetBridgeKuwoFlowTrace.h"
#import "AxsHeadsetBridgeAudioStatus.h"

%ctor {
    @autoreleasepool {
        NSString *bundle=[NSBundle mainBundle].bundleIdentifier;
        [AxsHeadsetBridgeConfig axs_headsetbridge_shared];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([bundle isEqual:@"com.yeelion.kwplayer"]) {
                axs_headsetbridge_audioStatusStart();
                axs_headsetbridge_kuwo_flowTraceStart();
                axs_headsetbridge_kuwo_diagnosticsStart();
            }
            uint64_t diagnosticGateStarted=axs_headsetbridge_kuwo_profileBegin();
            axs_headsetbridge_startGate();
            axs_headsetbridge_kuwo_profileEnd(AxsHeadsetBridgeKuwoProfileStartupGate,diagnosticGateStarted,NO);
            axs_headsetbridge_engineLog(@"control",@"merge.preserved_baselines_ready",@{@"integration_revision":@2,@"kuwo_control_revision":@1,@"audio_status_revision":@1,@"package_version":@"5.8.8.1"});
            if ([bundle isEqual:@"com.apple.springboard"]) {
                // Registration only when disabled; target gate owns each new connection.
                axs_headsetbridge_cloud_startSpringBoard();
                axs_headsetbridge_kuwo_startSpringBoard();
            } else if ([bundle isEqual:@"com.netease.cloudmusic"]) axs_headsetbridge_cloud_startMusic();
            else if ([bundle isEqual:@"com.yeelion.kwplayer"]) axs_headsetbridge_kuwo_startMusic();
        });
    }
}
