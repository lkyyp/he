#import "AxsHeadsetBridgeKuwoDiagnostics.h"
#import "AxsHeadsetBridgeKuwoRuntime.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <string.h>
#import <notify.h>

// Counters only on hot gate paths; no JSON, file output, private getter or
// configuration lookup here. Report at existing request/verify boundaries.
static _Atomic(bool) AxsHeadsetBridgeKuwoDiagnosticEnabled;
static double AxsHeadsetBridgeKuwoNanosecondsPerTick;
static _Atomic(uint64_t) AxsHeadsetBridgeKuwoMetricCount[AxsHeadsetBridgeKuwoProfileKindCount];
static _Atomic(uint64_t) AxsHeadsetBridgeKuwoMetricNanos[AxsHeadsetBridgeKuwoProfileKindCount];
static _Atomic(uint64_t) AxsHeadsetBridgeKuwoMetricMax[AxsHeadsetBridgeKuwoProfileKindCount];
static _Atomic(uint64_t) AxsHeadsetBridgeKuwoMetricFailures[AxsHeadsetBridgeKuwoProfileKindCount];
static uint64_t AxsHeadsetBridgeKuwoStartedTicks;
static NSUInteger AxsHeadsetBridgeKuwoMetricReports;
static uint64_t AxsHeadsetBridgeKuwoSampledLease;
static NSUInteger AxsHeadsetBridgeKuwoSampleCount;
static BOOL AxsHeadsetBridgeKuwoSampling;
static int AxsHeadsetBridgeKuwoDiagnosticLeaseToken=-1;
static BOOL AxsHeadsetBridgeKuwoDiagnosticTokenReady;

uint64_t axs_headsetbridge_kuwo_profileBegin(void) {
    if (!atomic_load_explicit(&AxsHeadsetBridgeKuwoDiagnosticEnabled,memory_order_acquire))return 0;
    uint64_t now=mach_absolute_time();
    if ((double)(now-AxsHeadsetBridgeKuwoStartedTicks)*AxsHeadsetBridgeKuwoNanosecondsPerTick>120.0e9)return 0;
    return now;
}
double axs_headsetbridge_kuwo_profileClockSeconds(void) {
    if (!atomic_load_explicit(&AxsHeadsetBridgeKuwoDiagnosticEnabled,memory_order_acquire))return 0;
    return (double)mach_absolute_time()*AxsHeadsetBridgeKuwoNanosecondsPerTick/1e9;
}
void axs_headsetbridge_kuwo_profileEnd(AxsHeadsetBridgeKuwoProfileKind kind,uint64_t started,BOOL failed) {
    if (!started || kind>=AxsHeadsetBridgeKuwoProfileKindCount) return;
    uint64_t ticks=mach_absolute_time()-started;
    uint64_t ns=(uint64_t)((double)ticks*AxsHeadsetBridgeKuwoNanosecondsPerTick);
    atomic_fetch_add(&AxsHeadsetBridgeKuwoMetricCount[kind],1);
    atomic_fetch_add(&AxsHeadsetBridgeKuwoMetricNanos[kind],ns);
    if (failed)atomic_fetch_add(&AxsHeadsetBridgeKuwoMetricFailures[kind],1);
    uint64_t prior=atomic_load(&AxsHeadsetBridgeKuwoMetricMax[kind]);
    while (prior<ns && !atomic_compare_exchange_weak(&AxsHeadsetBridgeKuwoMetricMax[kind],&prior,ns)) {}
}
void axs_headsetbridge_kuwo_profileReport(NSString *stage,uint64_t requestState) {
    if (![NSThread isMainThread] || !axs_headsetbridge_kuwo_profileBegin() || AxsHeadsetBridgeKuwoMetricReports>=24)return;
    @try {
        ++AxsHeadsetBridgeKuwoMetricReports;
        NSMutableDictionary *groups=[NSMutableDictionary dictionary];
        NSArray *names=@[@"canonical",@"relay",@"snapshot_total",@"snapshot_lock_wait",@"binding_total",@"startup_gate"];
        for (NSUInteger i=0;i<AxsHeadsetBridgeKuwoProfileKindCount;++i) {
            uint64_t count=atomic_load(&AxsHeadsetBridgeKuwoMetricCount[i]);
            uint64_t nanos=atomic_load(&AxsHeadsetBridgeKuwoMetricNanos[i]);
            groups[names[i]]=@{@"count":@(count),@"total_ms":@((double)nanos/1e6),@"max_ms":@((double)atomic_load(&AxsHeadsetBridgeKuwoMetricMax[i])/1e6),@"failures":@(atomic_load(&AxsHeadsetBridgeKuwoMetricFailures[i]))};
        }
        axs_headsetbridge_kuwo_log(@"kuwo.control_cost",@{@"stage":stage,@"request_session":@((uint32_t)(requestState>>32)),@"challenge":@((uint32_t)requestState),@"metrics":groups,@"note":@"Cumulative approximate counters; nested categories overlap, not additive or an atomic performance snapshot"});
    } @catch(NSException *e) { (void)e; }
}

static void axs_headsetbridge_kuwo_diagnosticScalar(NSMutableDictionary *out,id object,NSString *name,char result) {
    if (!object)return;
    SEL selector=NSSelectorFromString(name);
    @try {
        if (![object respondsToSelector:selector]) { out[[name stringByAppendingString:@"_status"]]=@"unsupported";return; }
        NSMethodSignature *sig=[object methodSignatureForSelector:selector];
        if (!sig || sig.numberOfArguments!=2 || sig.methodReturnLength!=(result=='B' ? sizeof(BOOL) : sizeof(int)) || strcmp(sig.methodReturnType,result=='B' ? "B" : "i")!=0) {
            out[[name stringByAppendingString:@"_status"]]=@"signature_mismatch";return;
        }
        if (result=='B')out[name]=@(((BOOL (*)(id,SEL))objc_msgSend)(object,selector));
        else out[name]=@(((int (*)(id,SEL))objc_msgSend)(object,selector));
    } @catch(NSException *e) { out[[name stringByAppendingString:@"_status"]]=@"exception"; }
}
static id axs_headsetbridge_kuwo_diagnosticObject(id object,NSString *name) {
    SEL selector=NSSelectorFromString(name);
    NSMethodSignature *sig=[object methodSignatureForSelector:selector];
    if (!sig || sig.numberOfArguments!=2 || sig.methodReturnLength!=sizeof(id) || strcmp(sig.methodReturnType,"@")!=0)return nil;
    return ((id (*)(id,SEL))objc_msgSend)(object,selector);
}
static BOOL axs_headsetbridge_kuwo_diagnosticContext(id manager,id player,id item,id center) {
    return manager && player && item && center &&
        axs_headsetbridge_kuwo_diagnosticObject(manager,@"currentPlayer")==player &&
        axs_headsetbridge_kuwo_diagnosticObject(manager,@"currentMediaItemInfo")==item &&
        axs_headsetbridge_kuwo_diagnosticObject(center,@"currentPlayer")==player;
}
void axs_headsetbridge_kuwo_recordPlayerState(id manager,id player,id item,id center,uint64_t lease,NSString *stage) {
    if (![NSThread isMainThread] || !axs_headsetbridge_kuwo_profileBegin() || AxsHeadsetBridgeKuwoSampling)return;
    AxsHeadsetBridgeKuwoSampling=YES;
    @try {
        uint64_t current=0;
        if (!AxsHeadsetBridgeKuwoDiagnosticTokenReady || notify_get_state(AxsHeadsetBridgeKuwoDiagnosticLeaseToken,&current)!=NOTIFY_STATUS_OK || current!=lease || (uint32_t)lease<=[NSProcessInfo processInfo].systemUptime || !axs_headsetbridge_bindingValid(@"kuwo",lease))return;
        if (AxsHeadsetBridgeKuwoSampledLease!=lease) { AxsHeadsetBridgeKuwoSampledLease=lease;AxsHeadsetBridgeKuwoSampleCount=0; }
        if (AxsHeadsetBridgeKuwoSampleCount>=4)return;
        // No singleton creation or queue restoration. Only objects already used by playback.
        if (![manager isKindOfClass:NSClassFromString(@"MediaPlayerManager")] || ![player isKindOfClass:NSClassFromString(@"KWMediaPlayer")] || ![center isKindOfClass:NSClassFromString(@"KWPlayControlCenter")])return;
        ++AxsHeadsetBridgeKuwoSampleCount;
        uint64_t start=mach_absolute_time();
        if (!axs_headsetbridge_kuwo_diagnosticContext(manager,player,item,center)) {
            axs_headsetbridge_kuwo_log(@"kuwo.player_state_skipped",@{@"stage":stage,@"session":@((uint32_t)(lease>>32)),@"reason":@"current_objects_changed"});return;
        }
        NSMutableDictionary *managerState=[NSMutableDictionary dictionary],*playerState=[NSMutableDictionary dictionary],*centerState=[NSMutableDictionary dictionary];
        for (NSString *name in @[@"isPlaying",@"readyToPlay",@"canPlay",@"isBuffering",@"isUserStopped",@"userStopped",@"isMute"])axs_headsetbridge_kuwo_diagnosticScalar(managerState,manager,name,'B');
        for (NSString *name in @[@"playState",@"playstate",@"errorCode"])axs_headsetbridge_kuwo_diagnosticScalar(managerState,manager,name,'i');
        for (NSString *name in @[@"isPlaying",@"canPlay",@"isBuffering",@"isMute"])axs_headsetbridge_kuwo_diagnosticScalar(playerState,player,name,'B');
        axs_headsetbridge_kuwo_diagnosticScalar(playerState,player,@"playState",'i');
        for (NSString *name in @[@"isPlaying",@"isBuffering",@"isUserStopped"])axs_headsetbridge_kuwo_diagnosticScalar(centerState,center,name,'B');
        axs_headsetbridge_kuwo_diagnosticScalar(centerState,center,@"playState",'i');
        AVAudioSession *audio=[AVAudioSession sharedInstance];NSMutableArray *outputs=[NSMutableArray array];
        for (AVAudioSessionPortDescription *port in audio.currentRoute.outputs)[outputs addObject:port.portType ?: @"unknown"];
        NSString *category=audio.category ?: @"unknown", *mode=audio.mode ?: @"unknown";
        NSUInteger options=audio.categoryOptions;
        double sampleRate=audio.sampleRate;
        float volume=audio.outputVolume;
        BOOL otherAudio=audio.otherAudioPlaying;
        BOOL contextStillMatches=axs_headsetbridge_kuwo_diagnosticContext(manager,player,item,center);
        double age=(double)(mach_absolute_time()-AxsHeadsetBridgeKuwoStartedTicks)*AxsHeadsetBridgeKuwoNanosecondsPerTick/1e9;
        double elapsed=(double)(mach_absolute_time()-start)*AxsHeadsetBridgeKuwoNanosecondsPerTick/1e6;
        if (!contextStillMatches) {
            axs_headsetbridge_kuwo_log(@"kuwo.player_state_skipped",@{@"stage":stage,@"session":@((uint32_t)(lease>>32)),@"reason":@"objects_changed_during_sample",@"sampling_ms":@(elapsed)});return;
        }
        // A getter can reenter application code. Discard the result if this
        // sample crossed an observed lease/selection change or expiration.
        if (notify_get_state(AxsHeadsetBridgeKuwoDiagnosticLeaseToken,&current)!=NOTIFY_STATUS_OK || current!=lease || (uint32_t)lease<=[NSProcessInfo processInfo].systemUptime || !axs_headsetbridge_bindingValid(@"kuwo",lease))return;
        axs_headsetbridge_kuwo_log(@"kuwo.player_state",@{@"stage":stage,@"session":@((uint32_t)(lease>>32)),@"manager":managerState,@"player":playerState,@"center":centerState,@"audio_category":category,@"audio_mode":mode,@"audio_options":@(options),@"sample_rate":@(sampleRate),@"output_volume":@(volume),@"other_audio_playing":@(otherAudio),@"output_types":outputs,@"diagnostics_age_seconds":@(age),@"same_context_before_after":@YES,@"sampling_ms":@(elapsed),@"note":@"Raw getter values, no enum decoding or policy changes. These diagnostic getters may affect timing."});
    } @catch(NSException *e) {
        @try { axs_headsetbridge_kuwo_log(@"kuwo.player_state_exception",@{@"name":e.name,@"stage":stage,@"session":@((uint32_t)(lease>>32))}); } @catch(NSException *ignored) { (void)ignored; }
    } @finally { AxsHeadsetBridgeKuwoSampling=NO; }
}

void axs_headsetbridge_kuwo_diagnosticsStart(void) {
    if (![NSThread isMainThread])return;
    @try {
        NSBundle *bundle=[NSBundle mainBundle];
        if (![bundle.bundleIdentifier isEqual:@"com.yeelion.kwplayer"] || ![[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:@"12.0.0"] || ![[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:@"11418"])return;
        static dispatch_once_t once;
        dispatch_once(&once,^{
            mach_timebase_info_data_t info;
            if (mach_timebase_info(&info)!=KERN_SUCCESS || !info.denom)return;
            AxsHeadsetBridgeKuwoNanosecondsPerTick=(double)info.numer/(double)info.denom;
            AxsHeadsetBridgeKuwoStartedTicks=mach_absolute_time();
            uint32_t registered=notify_register_check(AxsHeadsetBridgeKuwoLease,&AxsHeadsetBridgeKuwoDiagnosticLeaseToken);
            AxsHeadsetBridgeKuwoDiagnosticTokenReady=registered==NOTIFY_STATUS_OK;
            atomic_store_explicit(&AxsHeadsetBridgeKuwoDiagnosticEnabled,true,memory_order_release);
            axs_headsetbridge_kuwo_log(@"kuwo.diagnostics_ready",@{@"lease_registration":@(registered),@"max_state_samples_per_lease":@4,@"max_cost_reports":@24,@"window_seconds":@120});
            NSNotificationCenter *center=[NSNotificationCenter defaultCenter];
            for (NSString *name in @[AVAudioSessionInterruptionNotification,AVAudioSessionMediaServicesWereLostNotification,AVAudioSessionMediaServicesWereResetNotification]) {
                [center addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note){
                    @try {
                        if (!axs_headsetbridge_kuwo_profileBegin())return;
                        static NSUInteger eventCount;
                        if (eventCount>=12 || !axs_headsetbridge_enabledFor(@"kuwo"))return;
                        ++eventCount;
                        id type=note.userInfo[AVAudioSessionInterruptionTypeKey];
                        id options=note.userInfo[AVAudioSessionInterruptionOptionKey];
                        axs_headsetbridge_kuwo_log(@"kuwo.audio_event",@{@"notification":note.name,@"type_raw":[type isKindOfClass:[NSNumber class]] ? type : @(-1),@"options_raw":[options isKindOfClass:[NSNumber class]] ? options : @0});
                    } @catch(NSException *e) { (void)e; }
                }];
            }
        });
    } @catch(NSException *e) { (void)e; }
}
