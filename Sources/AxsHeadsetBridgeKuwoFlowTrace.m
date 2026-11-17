#import "AxsHeadsetBridgeKuwoFlowTrace.h"
#import "AxsHeadsetBridgeKuwoRuntime.h"
#import "AxsHeadsetBridgeAudioStatus.h"
#import <objc/runtime.h>
#import <substrate.h>
#import <dispatch/dispatch.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

// No app getters, object descriptions, blocks, argument inspection or playback
// calls. Hook originals are the ONLY calls into the observed playback chain.
// Budgets count attempted log writes, not guaranteed persistence by engineLog.
enum { FlowMaxWindows=12, FlowActionEntries=160, FlowCallbackEntries=80,
       FlowMaxEvents=2000, FlowMaxObjects=256, FlowSummaryReserve=12,
       FlowCallbackReserve=80, FlowMaxLateExitRecords=24 };
static const double FlowSeconds=10.0, FlowLateExitMaxAge=90.0;
static pthread_mutex_t FlowMutex=PTHREAD_MUTEX_INITIALIZER;
static double FlowTickSeconds;
static unsigned FlowEvents, FlowWindows, FlowObjectCount, FlowLateExitRecords;
static uint64_t FlowNextCall, FlowNextThread;
static struct { uintptr_t pointer; Class cls; } FlowObjects[FlowMaxObjects];
static __thread unsigned FlowBusy; // Covers ALL diagnostics, including logging.
static __thread uint64_t FlowThread;
typedef struct { uint64_t call; unsigned window,depth,rootDepth; } FlowContext;
static __thread FlowContext FlowTLS;
typedef struct {
    unsigned id,roots,action,callback,dropAction,dropCallback,dropGlobal;
    unsigned stale,inflight;
    double start,deadline,closed;
} FlowWindow;
static FlowWindow FlowCurrent;
typedef struct {
    const char *owner,*selector,*signature;
    BOOL root,callback,boundary;
    IMP replacement,original; // One immutable-after-install original per hook.
    unsigned status; // 0=pending, 1=installed, 2=permanently skipped.
    BOOL lateExit; // Only explicitly selected BOOL0 methods, never extra calls.
} FlowHook;
typedef struct {
    FlowContext saved;
    FlowHook *hook;
    uint64_t call,parent,thread;
    unsigned window,depth,receiver;
    const char *receiverClass;
    BOOL restore,tracked;
    double enteredMono,deadline; // Immutable original-window timestamps.
} FlowFrame;

static double FlowNow(void) { return (double)mach_absolute_time()*FlowTickSeconds; }
// All shared mutable counters/maps/windows use this small lock. Never log,
// allocate ObjC objects, inspect application objects or call an IMP under it.
static BOOL FlowTakeLocked(BOOL callback,BOOL control) {
    unsigned limit=FlowMaxEvents-FlowSummaryReserve-FlowMaxLateExitRecords-
        (control || callback ? 0 : FlowCallbackReserve);
    if (FlowEvents>=limit)return NO;
    ++FlowEvents;return YES;
}
static void FlowEmit(NSString *event,NSDictionary *fields) {
    ++FlowBusy;
    @try {
        NSMutableDictionary *out=[fields mutableCopy];
        out[@"flow_revision"]=@2;
        axs_headsetbridge_kuwo_log(event,out);
    } @catch(NSException *ignored) { (void)ignored; }
    @finally { --FlowBusy; }
}
static FlowWindow FlowCloseLocked(double now) {
    FlowWindow result=FlowCurrent;
    result.closed=now;
    FlowCurrent=(FlowWindow){0};
    return result;
}
static void FlowSummary(FlowWindow w) {
    if (!w.id)return;
    pthread_mutex_lock(&FlowMutex);
    BOOL emit=FlowEvents<FlowMaxEvents-(FlowMaxLateExitRecords-FlowLateExitRecords);
    if (emit)++FlowEvents; // Reserved solely for at most twelve summaries.
    unsigned total=FlowEvents;
    pthread_mutex_unlock(&FlowMutex);
    if (!emit)return;
    FlowEmit(@"kuwo.flow_window_summary",@{
        @"window":@(w.id),@"reason":@"monotonic_deadline",
        @"start_mono_s":@(w.start),@"deadline_mono_s":@(w.deadline),
        @"observed_close_mono_s":@(w.closed),
        @"summary_lag_s":@(w.closed>w.deadline ? w.closed-w.deadline : 0),
        @"root_actions":@(w.roots),@"action_entries":@(w.action),
        @"callback_entries":@(w.callback),@"dropped_action_entries":@(w.dropAction),
        @"dropped_callback_entries":@(w.dropCallback),
        @"dropped_global_events":@(w.dropGlobal),@"stale_exits_suppressed":@(w.stale),
        @"inflight_at_close":@(w.inflight),@"process_events_reserved":@(total),
        @"note":@"Entries have separate budgets; exits use global budget. Inflight at close is a snapshot, not a final return conclusion. Selected eventual exits may be logged against their original window only, within 90 seconds of entry and a process quota of 24; absence is inconclusive (age/budget/FlowBusy/IO). Main-queue timer may be delayed; logging can affect timing."});
}
static void FlowSchedule(unsigned window,double deadline);
static void FlowTimer(unsigned window) {
    ++FlowBusy;
    @try {
        FlowWindow ended={0};double next=0,now=0;
        pthread_mutex_lock(&FlowMutex);
        now=FlowNow();
        if (FlowCurrent.id==window) {
            if (now>=FlowCurrent.deadline)ended=FlowCloseLocked(now);
            else next=FlowCurrent.deadline;
        }
        pthread_mutex_unlock(&FlowMutex);
        FlowSummary(ended);
        // At most ONE timer per window. Only a clock/rounding-early delivery
        // reschedules it; deadlines never move. Old timers cannot close new windows.
        if (next)FlowSchedule(window,next);
    } @catch(NSException *ignored) { (void)ignored; }
    @finally { --FlowBusy; }
}
static void FlowSchedule(unsigned window,double deadline) {
    double delay=deadline-FlowNow();if (delay<0)delay=0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),
                   dispatch_get_main_queue(),^{ FlowTimer(window); });
}
static unsigned FlowReceiverLocked(uintptr_t pointer,Class cls) {
    for (unsigned i=0;i<FlowObjectCount;++i)
        if (FlowObjects[i].pointer==pointer && FlowObjects[i].cls==cls)return i+1;
    if (FlowObjectCount==FlowMaxObjects)return 0;
    unsigned i=FlowObjectCount++;
    FlowObjects[i].pointer=pointer;FlowObjects[i].cls=cls;return i+1;
}

static FlowFrame FlowBegin(FlowHook *hook,id receiver,unsigned rawCount,int a,int b) {
    FlowFrame f={0};
    if (FlowBusy)return f; // Logging reentrancy: original still runs unobserved.
    f.restore=YES;f.saved=FlowTLS;f.hook=hook;
    FlowTLS.call=0;FlowTLS.window=0;
    FlowTLS.depth=hook->boundary ? 1 : f.saved.depth+1;
    FlowTLS.rootDepth=(hook->boundary ? 0 : f.saved.rootDepth)+(hook->root ? 1 : 0);
    ++FlowBusy;
    @try {
        double now=0;FlowWindow ended={0},opened={0};
        // Runtime-only class lookup, no -class or any other app message.
        Class cls=object_getClass(receiver);
        uintptr_t pointer=(uintptr_t)(__bridge void *)receiver;
        const char *className=cls ? class_getName(cls) : "nil";
        pthread_mutex_lock(&FlowMutex);
        now=FlowNow();
        if (FlowCurrent.id && now>=FlowCurrent.deadline)ended=FlowCloseLocked(now);
        // A nested root never opens/extends a window, even after expiration.
        if (hook->root && !f.saved.rootDepth) {
            if (!FlowCurrent.id && FlowWindows<FlowMaxWindows &&
                FlowEvents<FlowMaxEvents-FlowSummaryReserve-FlowMaxLateExitRecords-FlowCallbackReserve) {
                FlowCurrent=(FlowWindow){.id=++FlowWindows,.start=now,.deadline=now+FlowSeconds};
                opened=FlowCurrent;
            }
            if (FlowCurrent.id)++FlowCurrent.roots; // Fixed deadline; never extend.
        }
        if (FlowCurrent.id) {
            unsigned *entries=hook->callback ? &FlowCurrent.callback : &FlowCurrent.action;
            unsigned *dropped=hook->callback ? &FlowCurrent.dropCallback : &FlowCurrent.dropAction;
            unsigned limit=hook->callback ? FlowCallbackEntries : FlowActionEntries;
            if (*entries>=limit)++*dropped;
            else if (!FlowTakeLocked(hook->callback,NO))++FlowCurrent.dropGlobal;
            else {
                ++*entries;++FlowCurrent.inflight;
                f.tracked=YES;f.window=FlowCurrent.id;f.call=++FlowNextCall;
                f.enteredMono=now;f.deadline=FlowCurrent.deadline;
                f.parent=(!hook->boundary && f.saved.window==f.window) ? f.saved.call : 0;
                f.depth=(!hook->boundary && f.saved.window==f.window) ? f.saved.depth : 0;
                if (!FlowThread)FlowThread=++FlowNextThread;
                f.thread=FlowThread;f.receiver=FlowReceiverLocked(pointer,cls);
                f.receiverClass=className;
            }
        }
        pthread_mutex_unlock(&FlowMutex);
        if (f.tracked) { FlowTLS.call=f.call;FlowTLS.window=f.window;FlowTLS.depth=f.depth+1; }
        FlowSummary(ended);
        if (opened.id) {
            // Schedule before any logging that could throw; only opening does
            // this. All later roots share its fixed 10-second deadline/budgets.
            FlowSchedule(opened.id,opened.deadline);
            pthread_mutex_lock(&FlowMutex);BOOL emit=FlowTakeLocked(NO,YES);pthread_mutex_unlock(&FlowMutex);
            if (emit)FlowEmit(@"kuwo.flow_window",@{@"window":@(opened.id),
                @"start_mono_s":@(opened.start),@"initial_deadline_mono_s":@(opened.deadline),
                @"fixed_window_seconds":@10,@"root_extends_window":@NO,@"max_windows":@12});
        }
        if (f.tracked) {
            NSMutableDictionary *fields=[@{
                @"window":@(f.window),@"call_id":@(f.call),@"parent_call_id":@(f.parent),
                @"depth":@(f.depth),@"thread":@(f.thread),@"main_thread":@(pthread_main_np()!=0),
                @"mono_s":@(now),@"hook_class":@(hook->owner),@"selector":@(hook->selector),
                @"receiver_class":@(className),@"receiver_id":@(f.receiver),
                @"receiver_map_full":@(f.receiver==0),@"callback_budget":@(hook->callback),
                @"async_boundary":@(hook->boundary)} mutableCopy];
            if (rawCount>0)fields[@"arg0_int_raw"]=@(a);
            if (rawCount>1)fields[@"arg1_int_raw"]=@(b);
            FlowEmit(@"kuwo.flow_enter",fields);
        }
    } @catch(NSException *ignored) { (void)ignored; }
    @finally { --FlowBusy; }
    return f;
}

static void FlowEnd(FlowFrame f,BOOL completed,BOOL hasBOOL,BOOL result) {
    if (!f.restore)return;
    ++FlowBusy;
    @try {
        if (f.tracked) {
            double now=0;BOOL emit=NO,late=NO,stale=NO;FlowWindow ended={0};
            pthread_mutex_lock(&FlowMutex);
            now=FlowNow();
            if (FlowCurrent.id==f.window) {
                if (FlowCurrent.inflight)--FlowCurrent.inflight;
                if (now>=FlowCurrent.deadline) {
                    stale=YES;++FlowCurrent.stale;ended=FlowCloseLocked(now);
                } else {
                    emit=FlowTakeLocked(f.hook->callback,NO);
                    if (!emit)++FlowCurrent.dropGlobal;
                }
            } else stale=YES;
            // Reserve only on the actual eventual return/exception, never via a
            // per-frame timer, and never reopen or extend any window.
            double age=now-f.enteredMono;
            if (stale && f.hook->lateExit && age>=0 && age<=FlowLateExitMaxAge &&
                FlowLateExitRecords<FlowMaxLateExitRecords && FlowEvents<FlowMaxEvents) {
                ++FlowLateExitRecords;++FlowEvents;emit=YES;late=YES;
            }
            pthread_mutex_unlock(&FlowMutex);
            FlowSummary(ended);
            if (emit) {
                NSMutableDictionary *fields=[@{
                    @"window":@(f.window),@"call_id":@(f.call),@"parent_call_id":@(f.parent),
                    @"depth":@(f.depth),@"thread":@(f.thread),@"main_thread":@(pthread_main_np()!=0),
                    @"mono_s":@(now),@"hook_class":@(f.hook->owner),@"selector":@(f.hook->selector),
                    @"receiver_class":@(f.receiverClass),@"receiver_id":@(f.receiver),
                    @"completed":@(completed),@"bool_return_known":@(hasBOOL && completed)} mutableCopy];
                if (hasBOOL && completed)fields[@"bool_return"]=@(result);
                if (age>=0 && age<=FlowLateExitMaxAge) {
                    fields[@"entered_mono_s"]=@(f.enteredMono);
                    fields[@"duration_s"]=@(age);
                }
                if (late) {
                    fields[@"original_deadline_mono_s"]=@(f.deadline);
                    fields[@"late_age_s"]=@(now>f.deadline ? now-f.deadline : 0);
                }
                FlowEmit(late ? @"kuwo.flow_late_exit" : @"kuwo.flow_exit",fields);
            }
        }
    } @catch(NSException *ignored) { (void)ignored; }
    @finally { FlowTLS=f.saved;--FlowBusy; }
}

// Each method owns a separate static IMP slot. Cast IMP to the exact validated
// C function signature at the call site; &slot.original is already IMP*, so
// there is no ARC-unsafe cast of an Objective-C ownership-qualified pointer.
// No @catch spans an original. @finally records exceptional exit then restores
// TLS; exceptions propagate unchanged and the original is called exactly once.
#define FLOW_BOOL(NAME) \
    static FlowHook NAME; \
    static BOOL NAME##Hook(id self,SEL cmd) { \
        FlowFrame f=FlowBegin(&NAME,self,0,0,0);BOOL value=NO,done=NO; \
        BOOL audioCandidate=f.tracked && strcmp(NAME.owner,"KWDecoderPlayer")==0; \
        AxsHeadsetBridgeAudioScope audioSaved=axs_headsetbridge_audioScopeEnter(audioCandidate,f.window,f.call); \
        @try { value=((BOOL (*)(id,SEL))NAME.original)(self,cmd);done=YES; } \
        @finally { axs_headsetbridge_audioScopeLeave(audioSaved);FlowEnd(f,done,YES,value); } \
        return value; \
    }
#define FLOW_VOID(NAME,PARAMS,TYPE,ARGS,N,A,B) \
    static FlowHook NAME; \
    static void NAME##Hook PARAMS { \
        FlowFrame f=FlowBegin(&NAME,self,N,A,B);BOOL done=NO; \
        @try { (TYPE NAME.original) ARGS;done=YES; } \
        @finally { FlowEnd(f,done,NO,NO); } \
    }
#define FLOW_VOID0(NAME) \
    FLOW_VOID(NAME,(id self,SEL cmd),(void (*)(id,SEL)),(self,cmd),0,0,0)
#define FLOW_INT(NAME) \
    FLOW_VOID(NAME,(id self,SEL cmd,int a),(void (*)(id,SEL,int)),(self,cmd,a),1,a,0)
#define FLOW_SLOT(NAME,OWNER,SELECTOR,SIG,ROOT,CB,BOUNDARY) \
    static FlowHook NAME={OWNER,SELECTOR,SIG,ROOT,CB,BOUNDARY,(IMP)NAME##Hook,NULL,0,NO}
#define FLOW_LATE_SLOT(NAME,OWNER,SELECTOR) \
    static FlowHook NAME={OWNER,SELECTOR,"B",NO,NO,NO,(IMP)NAME##Hook,NULL,0,YES}

FLOW_BOOL(FlowManagerPlay)
FLOW_SLOT(FlowManagerPlay,"MediaPlayerManager","play","B",YES,NO,NO);
FLOW_VOID0(FlowCenterMusic)
FLOW_SLOT(FlowCenterMusic,"KWPlayControlCenter","musicPlay","v",YES,NO,NO);
FLOW_BOOL(FlowCenterPlay)
FLOW_SLOT(FlowCenterPlay,"KWPlayControlCenter","play","B",YES,NO,NO);
FLOW_VOID0(FlowMediaPlay)
FLOW_SLOT(FlowMediaPlay,"KWMediaPlayer","play","v",NO,NO,NO);
FLOW_BOOL(FlowAudioPlay)
FLOW_SLOT(FlowAudioPlay,"KWAudioPlayer","play","B",NO,NO,NO);
FLOW_BOOL(FlowAudioStart)
FLOW_LATE_SLOT(FlowAudioStart,"KWAudioPlayer","startPlay");
FLOW_BOOL(FlowAudioInternal)
FLOW_SLOT(FlowAudioInternal,"KWAudioPlayer","playInternal","B",NO,NO,NO);
FLOW_BOOL(FlowAudioAV)
FLOW_SLOT(FlowAudioAV,"KWAudioPlayer","playInternalForAVPlayer","B",NO,NO,NO);
FLOW_VOID(FlowDownloadResult,(id self,SEL cmd,int a,int b),
          (void (*)(id,SEL,int,int)),(self,cmd,a,b),2,a,b)
FLOW_SLOT(FlowDownloadResult,"KWAudioPlayer","async_handlerDownloadResult:result:","vii",NO,YES,YES);
FLOW_VOID(FlowDownloadStatus,(id self,SEL cmd,int a,int b,id info),
          (void (*)(id,SEL,int,int,id)),(self,cmd,a,b,info),2,a,b)
FLOW_SLOT(FlowDownloadStatus,"KWAudioPlayer","async_handlerDownloadStatus:status:downloadInfo:","vii@",NO,YES,YES);
FLOW_VOID(FlowAVPrepare,(id self,SEL cmd,id asset,id keys,id url),
          (void (*)(id,SEL,id,id,id)),(self,cmd,asset,keys,url),0,0,0)
FLOW_SLOT(FlowAVPrepare,"KWAVAudioPlayer","prepareToPlayAsset:withKeys:withURL:","v@@@",NO,NO,NO);
FLOW_VOID0(FlowAVFailed)
FLOW_SLOT(FlowAVFailed,"KWAVAudioPlayer","playFailed","v",NO,YES,NO);
FLOW_BOOL(FlowDecoderPlay)
FLOW_LATE_SLOT(FlowDecoderPlay,"KWDecoderPlayer","Play");
// 12.0.0/11418 own-method runtime evidence: each is BOOL0 B16@0:8.
FLOW_BOOL(FlowDecoderPlayNew)
FLOW_LATE_SLOT(FlowDecoderPlayNew,"KWDecoderPlayer","Play_New");
FLOW_BOOL(FlowDecoderSession)
FLOW_LATE_SLOT(FlowDecoderSession,"KWDecoderPlayer","setAudioSession");
// Deliberately do not hook readAudioHead: high frequency consumed the action budget.
FLOW_BOOL(FlowDecoderQueue)
FLOW_LATE_SLOT(FlowDecoderQueue,"KWDecoderPlayer","createAudioQueue");
FLOW_BOOL(FlowDecoderStartQueue)
FLOW_LATE_SLOT(FlowDecoderStartQueue,"KWDecoderPlayer","StartAudioQueue");
FLOW_INT(FlowDecoderError)
FLOW_SLOT(FlowDecoderError,"KWDecoderPlayer","NotifyError:","vi",NO,YES,NO);
FLOW_INT(FlowDecoderState)
FLOW_SLOT(FlowDecoderState,"KWDecoderPlayer","KWAudioDecoderState:","vi",NO,YES,NO);
FLOW_BOOL(FlowOnlinePlay)
FLOW_SLOT(FlowOnlinePlay,"KWOnlineDecoderPlayer","Play","B",NO,NO,NO);
FLOW_INT(FlowOnlineError)
FLOW_SLOT(FlowOnlineError,"KWOnlineDecoderPlayer","NotifyError:","vi",NO,YES,NO);
FLOW_INT(FlowOnlineState)
FLOW_SLOT(FlowOnlineState,"KWOnlineDecoderPlayer","KWAudioDecoderState:","vi",NO,YES,NO);
FLOW_INT(FlowManagerState)
FLOW_SLOT(FlowManagerState,"MediaPlayerManager","onPlayStateChanged:","vi",NO,YES,NO);
// Raw runtime evidence: this overload takes TWO objects, unlike the int
// single-argument overload. Forward untouched; never inspect either object.
FLOW_VOID(FlowManagerStateObject,(id self,SEL cmd,id state,id object),
          (void (*)(id,SEL,id,id)),(self,cmd,state,object),0,0,0)
FLOW_SLOT(FlowManagerStateObject,"MediaPlayerManager","onPlayStateChanged:object:","v@@",NO,YES,NO);
FLOW_VOID0(FlowManagerFailed)
FLOW_SLOT(FlowManagerFailed,"MediaPlayerManager","sendPlayFailedNotification","v",NO,YES,NO);

static FlowHook *const FlowHooks[]={
    &FlowManagerPlay,&FlowCenterMusic,&FlowCenterPlay,&FlowMediaPlay,
    &FlowAudioPlay,&FlowAudioStart,&FlowAudioInternal,&FlowAudioAV,
    &FlowDownloadResult,&FlowDownloadStatus,&FlowAVPrepare,&FlowAVFailed,
    &FlowDecoderPlay,&FlowDecoderPlayNew,&FlowDecoderSession,
    &FlowDecoderQueue,&FlowDecoderStartQueue,&FlowDecoderError,&FlowDecoderState,
    &FlowOnlinePlay,&FlowOnlineError,&FlowOnlineState,
    &FlowManagerState,&FlowManagerStateObject,&FlowManagerFailed
};
#undef FLOW_BOOL
#undef FLOW_VOID
#undef FLOW_VOID0
#undef FLOW_INT
#undef FLOW_SLOT
#undef FLOW_LATE_SLOT

static const char *FlowUnqualified(const char *type) {
    if (!type)return "";
    while (*type && strchr("rnNoORV",*type))++type;
    return type;
}
static BOOL FlowTypeIs(char *owned,char expected) {
    const char *p=FlowUnqualified(owned);
    BOOL matches=p[0]==expected && p[1]=='\0';
    free(owned);return matches;
}
static const char *FlowValidate(Method method,const char *signature) {
    if (method_getNumberOfArguments(method)!=strlen(signature)+1)return "argument_count_mismatch";
    if (!FlowTypeIs(method_copyReturnType(method),signature[0]))return "return_type_mismatch";
    if (!FlowTypeIs(method_copyArgumentType(method,0),'@'))return "self_type_mismatch";
    if (!FlowTypeIs(method_copyArgumentType(method,1),':'))return "selector_type_mismatch";
    for (unsigned i=1;signature[i];++i)
        if (!FlowTypeIs(method_copyArgumentType(method,i+1),signature[i]))return "argument_type_mismatch";
    return NULL;
}
static void FlowControl(NSString *event,NSDictionary *fields) {
    pthread_mutex_lock(&FlowMutex);BOOL emit=FlowTakeLocked(NO,YES);pthread_mutex_unlock(&FlowMutex);
    if (emit)FlowEmit(event,fields);
}
static void FlowInstallPass(BOOL retry) {
    ++FlowBusy;
    @try {
        for (unsigned index=0;index<sizeof(FlowHooks)/sizeof(FlowHooks[0]);++index) {
            FlowHook *h=FlowHooks[index];if (h->status)continue;
            @try {
                Class cls=objc_getClass(h->owner);SEL selector=sel_registerName(h->selector);
                Method own=NULL;const char *reason=NULL,*actual="unavailable";
                if (!cls)reason="class_missing";
                else {
                    unsigned count=0;Method *methods=class_copyMethodList(cls,&count);
                    for (unsigned i=0;i<count;++i)
                        if (sel_isEqual(method_getName(methods[i]),selector)) { own=methods[i];break; }
                    free(methods);
                    if (!own)reason=class_getInstanceMethod(cls,selector) ?
                        "inherited_method_not_hooked" : "own_method_missing";
                    else {
                        actual=method_getTypeEncoding(own) ?: "unavailable";
                        reason=FlowValidate(own,h->signature);
                    }
                }
                if (!reason) {
                    // Slot is a genuine IMP, not an id/void** ownership cast.
                    MSHookMessageEx(cls,selector,h->replacement,&h->original);
                    h->status=1;
                } else if (cls || retry)h->status=2;
                FlowControl(@"kuwo.flow_install",@{
                    @"class":@(h->owner),@"selector":@(h->selector),
                    @"signature":@(h->signature),@"actual_encoding":@(actual),
                    @"installed":@(h->status==1),@"pass":@(retry ? 2 : 1),
                    @"reason":reason ? @(reason) : @"validated_own_method",
                    @"original_slot_nonnull":@(h->original!=NULL)});
            } @catch(NSException *ignored) {
                (void)ignored;h->status=2;
                FlowControl(@"kuwo.flow_install",@{@"class":@(h->owner),
                    @"selector":@(h->selector),@"signature":@(h->signature),
                    @"installed":@NO,@"reason":@"diagnostic_install_exception"});
            }
        }
    } @catch(NSException *ignored) { (void)ignored; }
    @finally { --FlowBusy; }
}

void axs_headsetbridge_kuwo_flowTraceStart(void) {
    if (!pthread_main_np()) {
        static dispatch_once_t enqueueOnce;
        dispatch_once(&enqueueOnce,^{ dispatch_async(dispatch_get_main_queue(),^{
            axs_headsetbridge_kuwo_flowTraceStart();
        }); });
        return;
    }
    if (FlowBusy)return;
    ++FlowBusy;
    @try {
        NSBundle *bundle=[NSBundle mainBundle];
        if (![bundle.bundleIdentifier isEqual:@"com.yeelion.kwplayer"] ||
            ![[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:@"12.0.0"] ||
            ![[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:@"11418"])return;
        static dispatch_once_t once;
        dispatch_once(&once,^{
            mach_timebase_info_data_t timebase;
            if (mach_timebase_info(&timebase)!=KERN_SUCCESS || !timebase.denom)return;
            FlowTickSeconds=(double)timebase.numer/(double)timebase.denom/1e9;
            FlowControl(@"kuwo.flow_policy",@{
                @"action_entry_budget":@160,@"callback_entry_budget":@80,
                @"process_event_budget":@2000,@"global_callback_headroom":@80,
                @"max_late_exit_records":@24,@"late_exit_max_age_s":@90,
                @"global_late_exit_headroom":@24,
                @"window_seconds":@10,@"max_windows":@12,@"object_map_capacity":@256,
                @"automatic_playback":@NO,@"getters":@NO,
                @"note":@"Late exits only observe actual returns/exceptions of tracked KWAudioPlayer.startPlay and KWDecoderPlayer Play/Play_New/setAudioSession/createAudioQueue/StartAudioQueue; readAudioHead hook disabled, within 90 seconds of entry and 24 process records; all events share 2000 with 24 late slots reserved. Original window/call/thread/receiver are retained. duration_s is entry-to-exit; late_age_s is time past the original deadline. Inflight summaries are close-time snapshots; absence of a late exit is inconclusive (90s/budget/FlowBusy/IO). No per-frame timer or window reopening. Passive natural root actions only. Nested roots do not extend/open windows. Independent roots share the current fixed deadline/budgets; no call extends a window. Callback name is not queue proof; async_handler methods deliberately reset synchronous parent. Object arguments omitted. IDs can alias pointer reuse; 0 means map full. Timers use main queue and may be delayed; monotonic checks still reject stale events. Instrumentation/log IO can affect timing."});
            FlowInstallPass(NO);
            // Exactly one fixed retry; only still-missing classes remain pending.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),
                           dispatch_get_main_queue(),^{ FlowInstallPass(YES); });
        });
    } @catch(NSException *ignored) { (void)ignored; }
    @finally { --FlowBusy; }
}
