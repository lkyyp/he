#import "AxsHeadsetBridgeAudioStatus.h"
#import "AxsHeadsetBridgeKuwoRuntime.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <dlfcn.h>
#import <errno.h>
#import <string.h>
#import <stdlib.h>

// Passive only. Never synthesize an NSError output pointer or call an audio API.
static pthread_mutex_t AxsHeadsetBridgeAudioMutex=PTHREAD_MUTEX_INITIALIZER;
static unsigned AxsHeadsetBridgeAudioOperations, AxsHeadsetBridgeAudioRecords;
static uint64_t AxsHeadsetBridgeAudioNextGeneration;
static double AxsHeadsetBridgeAudioTick;
static const double AxsHeadsetBridgeAudioMaxSeconds=90.0;
static __thread unsigned AxsHeadsetBridgeAudioBusy;
static __thread AxsHeadsetBridgeAudioScope AxsHeadsetBridgeAudioTLS;
typedef struct {
    BOOL tracked;
    double entered, deadline;
    uint64_t generation, call;
    unsigned window;
} AxsHeadsetBridgeAudioFrame;
static double axs_headsetbridge_audioNow(void) { return mach_absolute_time()*AxsHeadsetBridgeAudioTick; }
static void axs_headsetbridge_audioEmit(NSString *event,NSDictionary *fields) {
    ++AxsHeadsetBridgeAudioBusy;
    @try {
        pthread_mutex_lock(&AxsHeadsetBridgeAudioMutex);
        BOOL permit=AxsHeadsetBridgeAudioRecords<96;
        if (permit)++AxsHeadsetBridgeAudioRecords;
        pthread_mutex_unlock(&AxsHeadsetBridgeAudioMutex);
        if (permit) {
            NSMutableDictionary *row=[fields mutableCopy];row[@"audio_status_revision"]=@1;
            axs_headsetbridge_kuwo_log(event,row);
        }
    } @catch(NSException *ignored) { (void)ignored; }
    @finally { --AxsHeadsetBridgeAudioBusy; }
}
AxsHeadsetBridgeAudioScope axs_headsetbridge_audioScopeEnter(BOOL candidate,unsigned window,uint64_t call) {
    int savedErrno=errno;AxsHeadsetBridgeAudioScope saved=AxsHeadsetBridgeAudioTLS;saved.restore=NO;
    if (!AxsHeadsetBridgeAudioBusy && AxsHeadsetBridgeAudioTick>0 && (candidate || AxsHeadsetBridgeAudioTLS.depth)) {
        saved.restore=YES;
        if (!AxsHeadsetBridgeAudioTLS.depth) {
            pthread_mutex_lock(&AxsHeadsetBridgeAudioMutex);
            uint64_t generation=++AxsHeadsetBridgeAudioNextGeneration;
            pthread_mutex_unlock(&AxsHeadsetBridgeAudioMutex);
            AxsHeadsetBridgeAudioTLS=(AxsHeadsetBridgeAudioScope){.started=axs_headsetbridge_audioNow(),.generation=generation,.window=window,.call=call};
        }
        ++AxsHeadsetBridgeAudioTLS.depth;
    }
    errno=savedErrno;return saved;
}
void axs_headsetbridge_audioScopeLeave(AxsHeadsetBridgeAudioScope saved) {
    int savedErrno=errno;if (saved.restore) { saved.restore=NO;AxsHeadsetBridgeAudioTLS=saved; }errno=savedErrno;
}
static AxsHeadsetBridgeAudioFrame axs_headsetbridge_audioBegin(void) {
    AxsHeadsetBridgeAudioFrame f={0};
    if (AxsHeadsetBridgeAudioBusy || !AxsHeadsetBridgeAudioTLS.depth)return f;
    double now=axs_headsetbridge_audioNow();
    if (now-AxsHeadsetBridgeAudioTLS.started>AxsHeadsetBridgeAudioMaxSeconds)return f;
    pthread_mutex_lock(&AxsHeadsetBridgeAudioMutex);
    if (AxsHeadsetBridgeAudioOperations<64) { ++AxsHeadsetBridgeAudioOperations;f.tracked=YES; }
    pthread_mutex_unlock(&AxsHeadsetBridgeAudioMutex);
    if (f.tracked) {
        f.entered=now;f.deadline=AxsHeadsetBridgeAudioTLS.started+AxsHeadsetBridgeAudioMaxSeconds;
        f.generation=AxsHeadsetBridgeAudioTLS.generation;f.call=AxsHeadsetBridgeAudioTLS.call;f.window=AxsHeadsetBridgeAudioTLS.window;
    }
    return f;
}
static NSMutableDictionary *axs_headsetbridge_audioFields(AxsHeadsetBridgeAudioFrame f,const char *owner,const char *method,BOOL completed) {
    return [@{@"scope_generation":@(f.generation),@"flow_window":@(f.window),@"flow_root_call":@(f.call),
        @"entered_mono_s":@(f.entered),@"duration_s":@(axs_headsetbridge_audioNow()-f.entered),
        @"owner":@(owner),@"method":@(method),@"main_thread":@(pthread_main_np()!=0),@"completed":@(completed)} mutableCopy];
}
static void axs_headsetbridge_audioSessionEnd(AxsHeadsetBridgeAudioFrame f,const char *owner,const char *method,BOOL done,BOOL result,NSError *__autoreleasing *error,int active,uint64_t options,int64_t policy) {
    if (!f.tracked)return;
    ++AxsHeadsetBridgeAudioBusy;
    @try {
        if (axs_headsetbridge_audioNow()>f.deadline)return;
        NSMutableDictionary *row=axs_headsetbridge_audioFields(f,owner,method,done);
        row[@"return_known"]=@(done);if (done)row[@"returned"]=@(result);
        if (active>=0)row[@"active_argument"]=@(active!=0);
        row[@"options_raw"]=@(options);if (policy>=0)row[@"route_policy_raw"]=@(policy);
        row[@"error_pointer_present"]=@(error!=NULL);
        // NSError convention: output is undefined on success. Never inspect then.
        if (done && !result && error!=NULL) {
            NSError *observed=*error;row[@"error_output_observed"]=@YES;
            row[@"error_present"]=@(observed!=nil);
            if (observed) {
                NSString *domain=observed.domain;
                if ([domain isKindOfClass:[NSString class]])row[@"error_domain"]=[domain substringToIndex:MIN(domain.length,(NSUInteger)128)];
                row[@"error_code"]=@(observed.code);
            }
            row[@"error_output_note"]=@"Failure-time caller output; may be stale if original did not assign it";
        } else row[@"error_output_observed"]=@NO;
        axs_headsetbridge_audioEmit(@"kuwo.audio_session_result",row);
    } @catch(NSException *ignored) { (void)ignored; }
    @finally { --AxsHeadsetBridgeAudioBusy; }
}
// One independent IMP and one wrapper per class/selector, including superclass calls.
#define ALEX_AUDIO_METHOD(NAME,OWNER,METHOD,SIG,PARAMS,TYPE,ARGS,ACTIVE,OPTIONS,POLICY) \
    static IMP NAME##Original; \
    static BOOL NAME##Hook PARAMS { \
        int enteredErrno=errno;AxsHeadsetBridgeAudioFrame frame=axs_headsetbridge_audioBegin();BOOL value=NO,done=NO; \
        errno=enteredErrno; \
        @try { value=(TYPE NAME##Original) ARGS;done=YES; } \
        @finally { int returnedErrno=errno;axs_headsetbridge_audioSessionEnd(frame,OWNER,METHOD,done,value,error,ACTIVE,OPTIONS,POLICY);errno=returnedErrno; } \
        return value; \
    }
ALEX_AUDIO_METHOD(AlexAVActive,"AVAudioSession","setActive:error:","unused",
    (id self,SEL cmd,BOOL active,NSError *__autoreleasing *error),(BOOL (*)(id,SEL,BOOL,NSError *__autoreleasing *)),(self,cmd,active,error),active,0,-1)
ALEX_AUDIO_METHOD(AlexAVActiveOptions,"AVAudioSession","setActive:withOptions:error:","unused",
    (id self,SEL cmd,BOOL active,NSUInteger options,NSError *__autoreleasing *error),(BOOL (*)(id,SEL,BOOL,NSUInteger,NSError *__autoreleasing *)),(self,cmd,active,options,error),active,(uint64_t)options,-1)
ALEX_AUDIO_METHOD(AlexAVCategory,"AVAudioSession","setCategory:error:","unused",
    (id self,SEL cmd,id category,NSError *__autoreleasing *error),(BOOL (*)(id,SEL,id,NSError *__autoreleasing *)),(self,cmd,category,error),-1,0,-1)
ALEX_AUDIO_METHOD(AlexAVCategoryOptions,"AVAudioSession","setCategory:withOptions:error:","unused",
    (id self,SEL cmd,id category,NSUInteger options,NSError *__autoreleasing *error),(BOOL (*)(id,SEL,id,NSUInteger,NSError *__autoreleasing *)),(self,cmd,category,options,error),-1,(uint64_t)options,-1)
ALEX_AUDIO_METHOD(AlexKGActive,"KGAVAudioSession","setActive:error:","unused",
    (id self,SEL cmd,BOOL active,NSError *__autoreleasing *error),(BOOL (*)(id,SEL,BOOL,NSError *__autoreleasing *)),(self,cmd,active,error),active,0,-1)
ALEX_AUDIO_METHOD(AlexKGActiveOptions,"KGAVAudioSession","setActive:withOptions:error:","unused",
    (id self,SEL cmd,BOOL active,int options,NSError *__autoreleasing *error),(BOOL (*)(id,SEL,BOOL,int,NSError *__autoreleasing *)),(self,cmd,active,options,error),active,(uint64_t)options,-1)
ALEX_AUDIO_METHOD(AlexKGCategory,"KGAVAudioSession","setCategory:error:","unused",
    (id self,SEL cmd,id category,NSError *__autoreleasing *error),(BOOL (*)(id,SEL,id,NSError *__autoreleasing *)),(self,cmd,category,error),-1,0,-1)
ALEX_AUDIO_METHOD(AlexKGCategoryOptions,"KGAVAudioSession","setCategory:withOptions:error:","unused",
    (id self,SEL cmd,id category,int options,NSError *__autoreleasing *error),(BOOL (*)(id,SEL,id,int,NSError *__autoreleasing *)),(self,cmd,category,options,error),-1,(uint64_t)options,-1)
ALEX_AUDIO_METHOD(AlexFALActive,"FALiveKGAVAudioSession","setActive:error:","unused",
    (id self,SEL cmd,BOOL active,NSError *__autoreleasing *error),(BOOL (*)(id,SEL,BOOL,NSError *__autoreleasing *)),(self,cmd,active,error),active,0,-1)
ALEX_AUDIO_METHOD(AlexFALActiveOptions,"FALiveKGAVAudioSession","setActive:withOptions:error:","unused",
    (id self,SEL cmd,BOOL active,int options,NSError *__autoreleasing *error),(BOOL (*)(id,SEL,BOOL,int,NSError *__autoreleasing *)),(self,cmd,active,options,error),active,(uint64_t)options,-1)
ALEX_AUDIO_METHOD(AlexFALCategory,"FALiveKGAVAudioSession","setCategory:error:","unused",
    (id self,SEL cmd,id category,NSError *__autoreleasing *error),(BOOL (*)(id,SEL,id,NSError *__autoreleasing *)),(self,cmd,category,error),-1,0,-1)
ALEX_AUDIO_METHOD(AlexFALCategoryOptions,"FALiveKGAVAudioSession","setCategory:withOptions:error:","unused",
    (id self,SEL cmd,id category,int options,NSError *__autoreleasing *error),(BOOL (*)(id,SEL,id,int,NSError *__autoreleasing *)),(self,cmd,category,options,error),-1,(uint64_t)options,-1)
ALEX_AUDIO_METHOD(AlexAVCategoryMode,"AVAudioSession","setCategory:mode:options:error:","unused",
    (id self,SEL cmd,id category,id mode,NSUInteger options,NSError *__autoreleasing *error),(BOOL (*)(id,SEL,id,id,NSUInteger,NSError *__autoreleasing *)),(self,cmd,category,mode,options,error),-1,options,-1)
ALEX_AUDIO_METHOD(AlexAVCategoryPolicy,"AVAudioSession","setCategory:mode:routeSharingPolicy:options:error:","unused",
    (id self,SEL cmd,id category,id mode,AVAudioSessionRouteSharingPolicy policy,NSUInteger options,NSError *__autoreleasing *error),(BOOL (*)(id,SEL,id,id,AVAudioSessionRouteSharingPolicy,NSUInteger,NSError *__autoreleasing *)),(self,cmd,category,mode,policy,options,error),-1,options,(int64_t)policy)
ALEX_AUDIO_METHOD(AlexAVMode,"AVAudioSession","setMode:error:","unused",
    (id self,SEL cmd,id mode,NSError *__autoreleasing *error),(BOOL (*)(id,SEL,id,NSError *__autoreleasing *)),(self,cmd,mode,error),-1,0,-1)
#undef ALEX_AUDIO_METHOD
typedef struct { const char *owner,*selector; IMP replacement; IMP *original; unsigned argc; const char *args[7]; } AxsHeadsetBridgeAudioMethod;
static AxsHeadsetBridgeAudioMethod AxsHeadsetBridgeAudioMethods[]={
    {"AVAudioSession","setActive:error:",(IMP)AlexAVActiveHook,&AlexAVActiveOriginal,4,{"@",":","B","^@"}},
    {"AVAudioSession","setActive:withOptions:error:",(IMP)AlexAVActiveOptionsHook,&AlexAVActiveOptionsOriginal,5,{"@",":","B","Q","^@"}},
    {"AVAudioSession","setCategory:error:",(IMP)AlexAVCategoryHook,&AlexAVCategoryOriginal,4,{"@",":","@","^@"}},
    {"AVAudioSession","setCategory:withOptions:error:",(IMP)AlexAVCategoryOptionsHook,&AlexAVCategoryOptionsOriginal,5,{"@",":","@","Q","^@"}},
    {"KGAVAudioSession","setActive:error:",(IMP)AlexKGActiveHook,&AlexKGActiveOriginal,4,{"@",":","B","^@"}},
    {"KGAVAudioSession","setActive:withOptions:error:",(IMP)AlexKGActiveOptionsHook,&AlexKGActiveOptionsOriginal,5,{"@",":","B","i","^@"}},
    {"KGAVAudioSession","setCategory:error:",(IMP)AlexKGCategoryHook,&AlexKGCategoryOriginal,4,{"@",":","@","^@"}},
    {"KGAVAudioSession","setCategory:withOptions:error:",(IMP)AlexKGCategoryOptionsHook,&AlexKGCategoryOptionsOriginal,5,{"@",":","@","i","^@"}},
    {"FALiveKGAVAudioSession","setActive:error:",(IMP)AlexFALActiveHook,&AlexFALActiveOriginal,4,{"@",":","B","^@"}},
    {"FALiveKGAVAudioSession","setActive:withOptions:error:",(IMP)AlexFALActiveOptionsHook,&AlexFALActiveOptionsOriginal,5,{"@",":","B","i","^@"}},
    {"FALiveKGAVAudioSession","setCategory:error:",(IMP)AlexFALCategoryHook,&AlexFALCategoryOriginal,4,{"@",":","@","^@"}},
    {"FALiveKGAVAudioSession","setCategory:withOptions:error:",(IMP)AlexFALCategoryOptionsHook,&AlexFALCategoryOptionsOriginal,5,{"@",":","@","i","^@"}},
    {"AVAudioSession","setCategory:mode:options:error:",(IMP)AlexAVCategoryModeHook,&AlexAVCategoryModeOriginal,6,{"@",":","@","@","Q","^@"}},
    {"AVAudioSession","setCategory:mode:routeSharingPolicy:options:error:",(IMP)AlexAVCategoryPolicyHook,&AlexAVCategoryPolicyOriginal,7,{"@",":","@","@",@encode(AVAudioSessionRouteSharingPolicy),"Q","^@"}},
    {"AVAudioSession","setMode:error:",(IMP)AlexAVModeHook,&AlexAVModeOriginal,4,{"@",":","@","^@"}},
};

static __typeof__(&AudioQueueNewOutput) AxsHeadsetBridgeAQNewOriginal;
static __typeof__(&AudioQueueStart) AxsHeadsetBridgeAQStartOriginal;
static __typeof__(&AudioQueuePrime) AxsHeadsetBridgeAQPrimeOriginal;
static void axs_headsetbridge_audioQueueEnd(AxsHeadsetBridgeAudioFrame f,const char *method,BOOL completed,OSStatus status) {
    if (!f.tracked)return;
    ++AxsHeadsetBridgeAudioBusy;
    @try {
        if (axs_headsetbridge_audioNow()>f.deadline)return;
        NSMutableDictionary *row=axs_headsetbridge_audioFields(f,"AudioToolbox",method,completed);
        row[@"status_known"]=@(completed);
        if (completed) {
            row[@"osstatus"]=@((int32_t)status);
            uint32_t word=(uint32_t)status;char four[5]={0};BOOL printable=YES;
            for (unsigned i=0;i<4;++i) { unsigned byte=(word>>(24-8*i))&255;four[i]=(char)byte;if (byte<32 || byte>126)printable=NO; }
            if (printable)row[@"fourcc"]=[NSString stringWithUTF8String:four];
        }
        axs_headsetbridge_audioEmit(@"kuwo.audio_queue_result",row);
    } @catch(NSException *ignored) { (void)ignored; }
    @finally { --AxsHeadsetBridgeAudioBusy; }
}
static OSStatus axs_headsetbridge_AQNewOutput(const AudioStreamBasicDescription *format,AudioQueueOutputCallback callback,void *context,CFRunLoopRef loop,CFStringRef mode,UInt32 flags,AudioQueueRef *output) {
    int before=errno;AxsHeadsetBridgeAudioFrame frame=axs_headsetbridge_audioBegin();OSStatus status=0;BOOL done=NO;
    errno=before;
    @try { status=AxsHeadsetBridgeAQNewOriginal(format,callback,context,loop,mode,flags,output);done=YES; }
    @finally { int after=errno;axs_headsetbridge_audioQueueEnd(frame,"AudioQueueNewOutput",done,status);errno=after; }
    return status;
}
static OSStatus axs_headsetbridge_AQStart(AudioQueueRef queue,const AudioTimeStamp *time) {
    int before=errno;AxsHeadsetBridgeAudioFrame frame=axs_headsetbridge_audioBegin();OSStatus status=0;BOOL done=NO;
    errno=before;
    @try { status=AxsHeadsetBridgeAQStartOriginal(queue,time);done=YES; }
    @finally { int after=errno;axs_headsetbridge_audioQueueEnd(frame,"AudioQueueStart",done,status);errno=after; }
    return status;
}
static OSStatus axs_headsetbridge_AQPrime(AudioQueueRef queue,UInt32 frames,UInt32 *prepared) {
    int before=errno;AxsHeadsetBridgeAudioFrame frame=axs_headsetbridge_audioBegin();OSStatus status=0;BOOL done=NO;
    errno=before;
    @try { status=AxsHeadsetBridgeAQPrimeOriginal(queue,frames,prepared);done=YES; }
    @finally { int after=errno;axs_headsetbridge_audioQueueEnd(frame,"AudioQueuePrime",done,status);errno=after; }
    return status;
}
static const char *axs_headsetbridge_audioType(const char *s) {
    if (!s)return "";while (*s && strchr("rnNoORV",*s))++s;return s;
}
static BOOL axs_headsetbridge_audioTypeMatches(char *owned,const char *wanted) {
    BOOL result=strcmp(axs_headsetbridge_audioType(owned),axs_headsetbridge_audioType(wanted))==0;
    free(owned);return result;
}
static Method axs_headsetbridge_audioOwnMethod(Class cls,SEL selector) {
    unsigned count=0;Method found=NULL;Method *list=class_copyMethodList(cls,&count);
    for (unsigned i=0;i<count;++i)if (sel_isEqual(method_getName(list[i]),selector)) { found=list[i];break; }
    free(list);return found;
}
static BOOL axs_headsetbridge_audioValid(Method method,AxsHeadsetBridgeAudioMethod *item) {
    if (method_getNumberOfArguments(method)!=item->argc || !axs_headsetbridge_audioTypeMatches(method_copyReturnType(method),"B"))return NO;
    for (unsigned i=0;i<item->argc;++i)
        if (!axs_headsetbridge_audioTypeMatches(method_copyArgumentType(method,i),item->args[i]))return NO;
    return YES;
}
static void axs_headsetbridge_audioInstallMethod(AxsHeadsetBridgeAudioMethod *item) {
    Class cls=objc_getClass(item->owner);SEL selector=sel_registerName(item->selector);
    Method method=cls ? axs_headsetbridge_audioOwnMethod(cls,selector) : NULL;
    const char *reason=!cls ? "class_missing" : !method ? "own_method_missing_or_inherited" : !axs_headsetbridge_audioValid(method,item) ? "ABI_mismatch" : NULL;
    if (!reason)MSHookMessageEx(cls,selector,item->replacement,item->original);
    axs_headsetbridge_audioEmit(@"kuwo.audio_status_install",@{
        @"owner":@(item->owner),@"method":@(item->selector),@"attempted":@(reason==NULL),
        @"original_slot_nonnull":@(*item->original!=NULL),@"reason":reason ? @(reason) : @"validated_own_method_hook_requested"});
}
void axs_headsetbridge_audioStatusStart(void) {
    if (!pthread_main_np())return;
    NSBundle *bundle=[NSBundle mainBundle];
    if (![bundle.bundleIdentifier isEqual:@"com.yeelion.kwplayer"] ||
        ![[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:@"12.0.0"] ||
        ![[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:@"11418"])return;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        ++AxsHeadsetBridgeAudioBusy;
        @try {
            mach_timebase_info_data_t info={0};
            if (mach_timebase_info(&info)!=KERN_SUCCESS || !info.denom)return;
            AxsHeadsetBridgeAudioTick=(double)info.numer/info.denom/1e9;
            axs_headsetbridge_audioEmit(@"kuwo.audio_status_policy",@{
                @"max_operations":@64,@"max_records":@96,@"scope_max_seconds":@90,
                @"scope":@"same-thread natural decoder call; nested calls do not renew deadline",
                @"error_output":@"Read only after completed NO and non-NULL caller pointer; output may be stale",
                @"coverage":@"Asynchronous calls outside scope may be missed. Hook installation is not execution proof. No proactive audio calls."});
            for (unsigned i=0;i<sizeof(AxsHeadsetBridgeAudioMethods)/sizeof(AxsHeadsetBridgeAudioMethods[0]);++i)
                axs_headsetbridge_audioInstallMethod(&AxsHeadsetBridgeAudioMethods[i]);
#define ALEX_AUDIO_C_INSTALL(SYMBOL,REPLACEMENT,SLOT) do { \
    void *target=dlsym(RTLD_DEFAULT,SYMBOL); \
    if (target)MSHookFunction(target,(void *)REPLACEMENT,(void **)&SLOT); \
    axs_headsetbridge_audioEmit(@"kuwo.audio_status_install",@{@"owner":@"AudioToolbox",@"method":@SYMBOL,@"symbol_found":@(target!=NULL),@"original_slot_nonnull":@(SLOT!=NULL),@"note":@"Non-null trampoline is not proof of natural execution"}); \
} while(0)
            __typeof__(&AudioQueueNewOutput) checkNew=axs_headsetbridge_AQNewOutput;
            __typeof__(&AudioQueueStart) checkStart=axs_headsetbridge_AQStart;
            __typeof__(&AudioQueuePrime) checkPrime=axs_headsetbridge_AQPrime;
            (void)checkNew;(void)checkStart;(void)checkPrime;
            ALEX_AUDIO_C_INSTALL("AudioQueueNewOutput",axs_headsetbridge_AQNewOutput,AxsHeadsetBridgeAQNewOriginal);
            ALEX_AUDIO_C_INSTALL("AudioQueueStart",axs_headsetbridge_AQStart,AxsHeadsetBridgeAQStartOriginal);
            ALEX_AUDIO_C_INSTALL("AudioQueuePrime",axs_headsetbridge_AQPrime,AxsHeadsetBridgeAQPrimeOriginal);
#undef ALEX_AUDIO_C_INSTALL
        } @catch(NSException *ignored) { (void)ignored; }
        @finally { --AxsHeadsetBridgeAudioBusy; }
    });
}
