#import "AxsHeadsetBridgeGate.h"
#import "AxsHeadsetBridgePreferences.h"
#import <notify.h>
#import <os/log.h>
#import <unistd.h>
#import "AxsHeadsetBridgeKuwoDiagnostics.h"

// Canonical file remains the sole persistent configuration. Only SpringBoard
// publishes the relay; app readers cannot turn an invalid/stale relay into a lease.
static BOOL axs_headsetbridge_schema(NSDictionary *d) {
    return [d isKindOfClass:[NSDictionary class]] && [d[@"enabled"] isKindOfClass:[NSNumber class]] && [d[@"selectionEpoch"] isKindOfClass:[NSNumber class]] && [d[@"selectionEpoch"] unsignedLongLongValue] && [@[@"cloud",@"kuwo"] containsObject:d[@"selectedApp"]];
}
static NSDictionary *axs_headsetbridge_canonicalUnmeasured(NSMutableDictionary *diagnostic) {
    NSString *path=axs_headsetbridge_preferencesPath();
    NSError *error=nil;
    NSData *data=[NSData dataWithContentsOfFile:path options:0 error:&error];
    diagnostic[@"config_path"]=path ?: @"";
    if (!data) {
        diagnostic[@"file_status"]=@"read_failed";
        diagnostic[@"error_domain"]=error.domain ?: @"";
        diagnostic[@"error_code"]=@(error.code);
        NSError *underlying=error.userInfo[NSUnderlyingErrorKey];
        diagnostic[@"underlying_domain"]=underlying.domain ?: @"";
        diagnostic[@"underlying_code"]=@(underlying.code);
        return nil;
    }
    if (data.length>65536) { diagnostic[@"file_status"]=@"oversized";return nil; }
    id d=[NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:&error];
    if (!axs_headsetbridge_schema(d)) {
        diagnostic[@"file_status"]=d ? @"invalid_schema" : @"decode_failed";
        diagnostic[@"error_domain"]=error.domain ?: @"";diagnostic[@"error_code"]=@(error.code);return nil;
    }
    diagnostic[@"file_status"]=@"valid";
    // Normalize to only the three control fields; compare entire snapshots.
    return @{@"enabled":@([d[@"enabled"] boolValue]),@"selectedApp":d[@"selectedApp"],@"selectionEpoch":d[@"selectionEpoch"]};
}
static NSDictionary *axs_headsetbridge_canonical(NSMutableDictionary *diagnostic) {
    uint64_t started=axs_headsetbridge_kuwo_profileBegin();
    NSDictionary *result=nil;
    @try { result=axs_headsetbridge_canonicalUnmeasured(diagnostic); return result; }
    @finally { axs_headsetbridge_kuwo_profileEnd(AxsHeadsetBridgeKuwoProfileCanonical,started,result==nil); }
}
static int AxsHeadsetBridgeRelaySequence=-1,AxsHeadsetBridgeRelayFlags=-1,AxsHeadsetBridgeRelayEpoch=-1;
static BOOL AxsHeadsetBridgeRelayReady;
static void axs_headsetbridge_relaySetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        uint32_t a=notify_register_check("com.axs.headsetbridge.config.sequence",&AxsHeadsetBridgeRelaySequence);
        uint32_t b=notify_register_check("com.axs.headsetbridge.config.flags",&AxsHeadsetBridgeRelayFlags);
        uint32_t c=notify_register_check("com.axs.headsetbridge.config.epoch",&AxsHeadsetBridgeRelayEpoch);
        AxsHeadsetBridgeRelayReady=a==NOTIFY_STATUS_OK && b==NOTIFY_STATUS_OK && c==NOTIFY_STATUS_OK;
        axs_headsetbridge_engineLog(@"control",@"config.relay_registration",@{@"sequence_result":@(a),@"flags_result":@(b),@"epoch_result":@(c),@"ready":@(AxsHeadsetBridgeRelayReady)});
    });
}
static NSDictionary *axs_headsetbridge_readRelayUnmeasured(void) {
    axs_headsetbridge_relaySetup();
    if (!AxsHeadsetBridgeRelayReady)return nil;
    uint64_t first=0,last=0,flags=0,epoch=0;
    if (notify_get_state(AxsHeadsetBridgeRelaySequence,&first)!=NOTIFY_STATUS_OK || !first || (first&1))return nil;
    if (notify_get_state(AxsHeadsetBridgeRelayFlags,&flags)!=NOTIFY_STATUS_OK || notify_get_state(AxsHeadsetBridgeRelayEpoch,&epoch)!=NOTIFY_STATUS_OK || notify_get_state(AxsHeadsetBridgeRelaySequence,&last)!=NOTIFY_STATUS_OK || first!=last || (last&1))return nil;
    if (!(flags&8) || (flags & ~15ULL) || !epoch)return nil;
    uint64_t target=(flags>>1)&3;
    if (target!=1 && target!=2)return nil;
    return @{@"enabled":@((flags&1)!=0),@"selectedApp":target==1 ? @"cloud" : @"kuwo",@"selectionEpoch":@(epoch)};
}
static NSDictionary *axs_headsetbridge_readRelay(void) {
    uint64_t started=axs_headsetbridge_kuwo_profileBegin();
    NSDictionary *result=nil;
    @try { result=axs_headsetbridge_readRelayUnmeasured(); return result; }
    @finally { axs_headsetbridge_kuwo_profileEnd(AxsHeadsetBridgeKuwoProfileRelay,started,result==nil); }
}
static BOOL axs_headsetbridge_syncRelay(NSDictionary *canonical, BOOL forceReset) {
    // Called only on the SpringBoard main thread. Notification is a hint, not a wake guarantee.
    if (![NSThread isMainThread] || ![[NSBundle mainBundle].bundleIdentifier isEqual:@"com.apple.springboard"])return NO;
    axs_headsetbridge_relaySetup();if (!AxsHeadsetBridgeRelayReady)return NO;
    if (!forceReset && canonical && [canonical isEqual:axs_headsetbridge_readRelay()])return YES;
    uint64_t flags=0,epoch=0,version=0;
    if (canonical) { flags=8|([canonical[@"enabled"] boolValue]?1:0)|([canonical[@"selectedApp"] isEqual:@"cloud"]?2:4);epoch=[canonical[@"selectionEpoch"] unsignedLongLongValue]; }
    if (notify_get_state(AxsHeadsetBridgeRelaySequence,&version)!=NOTIFY_STATUS_OK)return NO;
    uint64_t odd=(version&~1ULL)+1;
    if (notify_set_state(AxsHeadsetBridgeRelaySequence,odd)!=NOTIFY_STATUS_OK)return NO;
    // Invalidate old capabilities before committing a changed configuration.
    BOOL cloudRevoked=axs_headsetbridge_revokeBinding(@"cloud");
    BOOL kuwoRevoked=axs_headsetbridge_revokeBinding(@"kuwo");
    if (!cloudRevoked || !kuwoRevoked) {
        axs_headsetbridge_engineLog(@"control",@"config.relay_revoke_failed",@{@"cloud_revoked":@(cloudRevoked),@"kuwo_revoked":@(kuwoRevoked),@"sequence_held_odd":@(odd)});
        return NO; // Relay remains odd; do not recommit an old enabled capability.
    }
    uint32_t a=notify_set_state(AxsHeadsetBridgeRelayFlags,flags);
    uint32_t b=notify_set_state(AxsHeadsetBridgeRelayEpoch,epoch);
    uint32_t c=NOTIFY_STATUS_FAILED;
    if (a==NOTIFY_STATUS_OK && b==NOTIFY_STATUS_OK)c=notify_set_state(AxsHeadsetBridgeRelaySequence,odd+1);
    uint32_t posted=c==NOTIFY_STATUS_OK ? notify_post("com.axs.headsetbridge.config.changed") : NOTIFY_STATUS_FAILED;
    axs_headsetbridge_engineLog(@"control",@"config.relay_publish",@{@"enabled":canonical ? canonical[@"enabled"] : @NO,@"selected_app":canonical ? canonical[@"selectedApp"] : @"invalid",@"epoch":@(epoch),@"sequence":@(odd+1),@"flags_result":@(a),@"epoch_result":@(b),@"commit_result":@(c),@"post_result":@(posted)});
    return c==NOTIFY_STATUS_OK;
}
static void axs_headsetbridge_configDiagnostic(NSDictionary *row) {
    // Log once for each observed result/state, not on every private getter.
    static NSMutableDictionary *lastByBundle;static dispatch_once_t once;
    dispatch_once(&once,^{lastByBundle=[NSMutableDictionary dictionary];});
    NSString *bundle=[NSBundle mainBundle].bundleIdentifier ?: @"unknown";
    @synchronized(lastByBundle) {
        if ([lastByBundle[bundle] isEqual:row])return;
        lastByBundle[bundle]=[row copy];
    }
    axs_headsetbridge_engineLog(@"control",@"config.decision",row);
}
static NSDictionary *axs_headsetbridge_snapshotInternal(void) {
    NSMutableDictionary *status=[NSMutableDictionary dictionary];
    NSDictionary *file=axs_headsetbridge_canonical(status);
    BOOL sb=[[NSBundle mainBundle].bundleIdentifier isEqual:@"com.apple.springboard"];
    if (sb) {
        BOOL committed=axs_headsetbridge_syncRelay(file,NO);
        status[@"relay_committed"]=@(committed);
        if (!committed) file=nil;
        status[@"source"]=file ? @"canonical" : @"closed";
        status[@"enabled"]=file ? file[@"enabled"] : @NO;
        status[@"selected_app"]=file ? file[@"selectedApp"] : @"invalid";
        status[@"epoch"]=file ? file[@"selectionEpoch"] : @0;
        axs_headsetbridge_configDiagnostic(status);
        return file ?: @{};
    }
    NSDictionary *relay=axs_headsetbridge_readRelay();
    // Even a valid app-readable file must agree with SB's committed control state.
    // Valid disabled/other-target file can never be bypassed by an enabled relay.
    // Remember a canonical change already seen. A later read failure must not
    // resurrect a relay that we previously rejected. Epochs are compared by identity.
    static NSDictionary *pendingCanonical;
    if (file && ![file isEqual:relay]) pendingCanonical=[file copy];
    BOOL pendingConfirmed=!pendingCanonical || [pendingCanonical isEqual:relay];
    if (pendingCanonical && pendingConfirmed) pendingCanonical=nil;
    BOOL consistent=relay && pendingConfirmed && (!file || [file isEqual:relay]);
    status[@"waiting_for_observed_canonical"]=@(pendingCanonical!=nil);
    NSDictionary *effective=consistent ? (file ?: relay) : nil;
    status[@"source"]=effective ? (file ? @"canonical_confirmed_by_relay" : @"springboard_relay") : @"closed";
    status[@"relay_valid"]=@(relay!=nil);status[@"canonical_relay_agree"]=@(!file || [file isEqual:relay]);
    status[@"enabled"]=effective ? effective[@"enabled"] : @NO;
    status[@"selected_app"]=effective ? effective[@"selectedApp"] : @"invalid";
    status[@"epoch"]=effective ? effective[@"selectionEpoch"] : @0;
    axs_headsetbridge_configDiagnostic(status);
    return effective ?: @{};
}

static NSDictionary *axs_headsetbridge_snapshot(void) {
    static NSObject *lock;static dispatch_once_t once;
    dispatch_once(&once,^{lock=[NSObject new];});
    uint64_t started=axs_headsetbridge_kuwo_profileBegin();
    @synchronized(lock) {
        axs_headsetbridge_kuwo_profileEnd(AxsHeadsetBridgeKuwoProfileLockWait,started,NO);
        NSDictionary *result=nil;
        @try { result=axs_headsetbridge_snapshotInternal(); return result; }
        @finally { axs_headsetbridge_kuwo_profileEnd(AxsHeadsetBridgeKuwoProfileSnapshot,started,result.count==0); }
    }
}

void axs_headsetbridge_startGate(void) {
    axs_headsetbridge_relaySetup();
    if ([[NSBundle mainBundle].bundleIdentifier isEqual:@"com.apple.springboard"]) {
        // Do not allow a previous SB lifetime's leases to survive initialization.
        NSMutableDictionary *status=[NSMutableDictionary dictionary];
        (void)axs_headsetbridge_syncRelay(axs_headsetbridge_canonical(status),YES);
    } else {
        static int token;
        uint32_t result=notify_register_dispatch("com.axs.headsetbridge.config.changed",&token,dispatch_get_main_queue(),^(int t){
            (void)t;(void)axs_headsetbridge_snapshot();
            [[NSNotificationCenter defaultCenter] postNotificationName:AxsHeadsetBridgePreferencesChanged object:nil];
        });
        axs_headsetbridge_engineLog(@"control",@"config.relay_observer",@{@"registration":@(result)});
    }
    (void)axs_headsetbridge_snapshot();
}

BOOL axs_headsetbridge_enabledFor(NSString *engine) {
    NSDictionary *d = axs_headsetbridge_snapshot();
    return [d[@"enabled"] boolValue] && [d[@"selectedApp"] isEqual:engine];
}
uint64_t axs_headsetbridge_configurationEpoch(void) { return [axs_headsetbridge_snapshot()[@"selectionEpoch"] unsignedLongLongValue]; }
NSString *axs_headsetbridge_selectedBundle(void) {
    NSDictionary *d=axs_headsetbridge_snapshot();
    if (![d[@"enabled"] boolValue]) return nil;
    return [d[@"selectedApp"] isEqual:@"cloud"] ? @"com.netease.cloudmusic" : @"com.yeelion.kwplayer";
}

// Single writer: SpringBoard main queue. All app readers validate an even commit
// sequence before/after reading immutable (lease, configurationEpoch) values.
typedef struct { int sequence, lease, epoch; BOOL ready; } AxsHeadsetBridgeBinding;
static AxsHeadsetBridgeBinding AxsHeadsetBridgeCloudBinding, AxsHeadsetBridgeKuwoBinding;
static AxsHeadsetBridgeBinding *axs_headsetbridge_binding(NSString *engine) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AxsHeadsetBridgeBinding *bindings[] = { &AxsHeadsetBridgeCloudBinding, &AxsHeadsetBridgeKuwoBinding };
        NSArray *engines=@[@"cloud",@"kuwo"];
        for (NSUInteger i=0;i<2;++i) {
            AxsHeadsetBridgeBinding *b=bindings[i];
            NSString *prefix=[@"com.axs.headsetbridge.binding." stringByAppendingString:engines[i]];
            uint32_t a=notify_register_check([[prefix stringByAppendingString:@".sequence"] UTF8String], &b->sequence);
            uint32_t c=notify_register_check([[prefix stringByAppendingString:@".lease"] UTF8String], &b->lease);
            uint32_t d=notify_register_check([[prefix stringByAppendingString:@".epoch"] UTF8String], &b->epoch);
            b->ready=a==NOTIFY_STATUS_OK && c==NOTIFY_STATUS_OK && d==NOTIFY_STATUS_OK;
        }
    });
    if ([engine isEqual:@"cloud"]) return &AxsHeadsetBridgeCloudBinding;
    if ([engine isEqual:@"kuwo"]) return &AxsHeadsetBridgeKuwoBinding;
    return NULL;
}
static BOOL axs_headsetbridge_writeBinding(NSString *engine,uint64_t lease,uint64_t epoch) {
    if (![NSThread isMainThread] || ![[[NSBundle mainBundle] bundleIdentifier] isEqual:@"com.apple.springboard"]) return NO;
    AxsHeadsetBridgeBinding *b=axs_headsetbridge_binding(engine);
    if (!b || !b->ready) return NO;
    uint64_t version=0;
    if (notify_get_state(b->sequence,&version)!=NOTIFY_STATUS_OK) return NO;
    uint64_t odd=(version & ~1ULL)+1;
    if (!odd) odd=1;
    if (notify_set_state(b->sequence,odd)!=NOTIFY_STATUS_OK) return NO;
    if (notify_set_state(b->lease,lease)!=NOTIFY_STATUS_OK || notify_set_state(b->epoch,epoch)!=NOTIFY_STATUS_OK) return NO; // remains odd: readers fail closed
    return notify_set_state(b->sequence,odd+1)==NOTIFY_STATUS_OK;
}
BOOL axs_headsetbridge_publishBinding(NSString *engine,uint64_t lease,uint64_t expectedEpoch) {
    NSDictionary *before=axs_headsetbridge_snapshot();
    if (!lease || !expectedEpoch || expectedEpoch != [before[@"selectionEpoch"] unsignedLongLongValue] || ![before[@"enabled"] boolValue] || ![before[@"selectedApp"] isEqual:engine]) return NO;
    uint64_t epoch=[before[@"selectionEpoch"] unsignedLongLongValue];
    if (!axs_headsetbridge_writeBinding(engine,lease,epoch)) return NO;
    NSDictionary *after=axs_headsetbridge_snapshot();
    return [after isEqual:before]; // changed configuration never publishes a usable old lease
}
BOOL axs_headsetbridge_revokeBinding(NSString *engine) { return axs_headsetbridge_writeBinding(engine,0,0); }
static BOOL axs_headsetbridge_bindingValidUnmeasured(NSString *engine,uint64_t expectedLease) {
    NSDictionary *before=axs_headsetbridge_snapshot();
    if (!expectedLease || ![before[@"enabled"] boolValue] || ![before[@"selectedApp"] isEqual:engine]) return NO;
    AxsHeadsetBridgeBinding *b=axs_headsetbridge_binding(engine);
    if (!b || !b->ready) return NO;
    uint64_t first=0,second=0,lease=0,epoch=0;
    if (notify_get_state(b->sequence,&first)!=NOTIFY_STATUS_OK || !first || (first & 1)) return NO;
    if (notify_get_state(b->lease,&lease)!=NOTIFY_STATUS_OK || notify_get_state(b->epoch,&epoch)!=NOTIFY_STATUS_OK || notify_get_state(b->sequence,&second)!=NOTIFY_STATUS_OK) return NO;
    if (first!=second || (second & 1) || lease!=expectedLease || epoch!=[before[@"selectionEpoch"] unsignedLongLongValue]) return NO;
    return [before isEqual:axs_headsetbridge_snapshot()];
}
BOOL axs_headsetbridge_bindingValid(NSString *engine,uint64_t expectedLease) {
    uint64_t started=axs_headsetbridge_kuwo_profileBegin();
    BOOL result=NO;
    @try { result=axs_headsetbridge_bindingValidUnmeasured(engine,expectedLease); return result; }
    @finally { axs_headsetbridge_kuwo_profileEnd(AxsHeadsetBridgeKuwoProfileBinding,started,!result); }
}
void axs_headsetbridge_engineLog(NSString *engine,NSString *event,NSDictionary *fields) {
    static dispatch_queue_t queue; static os_log_t log; static dispatch_once_t once;
    dispatch_once(&once,^{ queue=dispatch_queue_create("com.axs.headsetbridge.log",DISPATCH_QUEUE_SERIAL);log=os_log_create("com.axs.headsetbridge","playback"); });
    NSMutableDictionary *row=[NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
    row[@"engine"]=engine;row[@"event"]=event;row[@"pid"]=@(getpid());row[@"bundle"]=[NSBundle mainBundle].bundleIdentifier ?: @"unknown";
    row[@"time"]=@([NSDate date].timeIntervalSince1970);row[@"uptime"]=@([NSProcessInfo processInfo].systemUptime);row[@"merge_revision"]=@3;row[@"experiment"]=@"kuwo-state-cost-diagnostics";
    NSData *data=[NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil];if (!data)return;
    os_log_with_type(log,OS_LOG_TYPE_DEFAULT,"%{public}@",[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    dispatch_async(queue,^{ @try {
        BOOL sb=[[[NSBundle mainBundle] bundleIdentifier] isEqual:@"com.apple.springboard"];
        NSString *path=sb ? @"/var/mobile/Library/Logs/HeadsetBridge-springboard.jsonl" : [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/HeadsetBridge-music.jsonl"];
        NSFileManager *fm=[NSFileManager defaultManager];[fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if ([[fm attributesOfItemAtPath:path error:nil] fileSize]>2*1024*1024) { NSString *old=[path stringByAppendingString:@".previous"];[fm removeItemAtPath:old error:nil];if (![fm moveItemAtPath:path toPath:old error:nil])return; }
        if (![fm fileExistsAtPath:path])[fm createFileAtPath:path contents:nil attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication}];
        NSFileHandle *handle=[NSFileHandle fileHandleForWritingAtPath:path];if (!handle)return;
        NSMutableData *line=[data mutableCopy];[line appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];[handle seekToEndOfFile];[handle writeData:line];[handle closeFile];
    } @catch(NSException *e) { (void)e; } });
}
