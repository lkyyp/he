#import "AxsHeadsetCardTimerRuntime.h"
#import "AxsHeadsetBridgeCardConfig.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <mach/mach_time.h>
#import <string.h>

static NSString *const AxsHeadsetCardTimerBatteryClass=@"SharingViewService.HeadphoneBatteryViewController";
// Delay is snapshotted per newly recognized card, never renewed by layout.
static char AxsHeadsetCardTimerContextKey;
static char AxsHeadsetCardTimerDisappearingKey;
static void (*AxsHeadsetCardTimerOriginalMove)(UIView *,SEL);
static void (*AxsHeadsetCardTimerOriginalAppear)(UIViewController *,SEL,BOOL);
static void (*AxsHeadsetCardTimerOriginalDisappear)(UIViewController *,SEL,BOOL);
static NSHashTable *AxsHeadsetCardTimerObservedViews;
static void axs_headsetcardtimer_viewMoved(UIView *view);
static void axs_headsetcardtimer_installLifecycle(void);
static void axs_headsetcardtimer_discover(NSString *stage,UIViewController *hint);
static void axs_headsetcardtimer_eventDiscovery(NSString *stage,UIViewController *hint);

@interface AxsHeadsetCardTimerContext : NSObject
@property(nonatomic,weak) UIView *axs_headsetcardtimer_view;
@property(nonatomic,weak) UIViewController *axs_headsetcardtimer_battery;
@property(nonatomic,weak) UIWindow *axs_headsetcardtimer_window;
@property(nonatomic) uint64_t axs_headsetcardtimer_started;
@property(nonatomic) BOOL axs_headsetcardtimer_cancelled;
@property(nonatomic) BOOL axs_headsetcardtimer_attempted;
@end
@implementation AxsHeadsetCardTimerContext
@end

static double axs_headsetcardtimer_elapsed(uint64_t start) {
    static mach_timebase_info_data_t info;static dispatch_once_t once;
    dispatch_once(&once,^{mach_timebase_info(&info);});
    if (!info.denom)return -1;
    return (double)(mach_absolute_time()-start)*(double)info.numer/(double)info.denom/1e9;
}
static UIViewController *axs_headsetcardtimer_battery(UIView *view) {
    UIResponder *cursor=view;
    NSHashTable *seen=[NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (NSUInteger i=0;cursor && i<32;++i) {
        if ([seen containsObject:cursor])return nil;
        [seen addObject:cursor];
        if ([NSStringFromClass([cursor class]) isEqual:AxsHeadsetCardTimerBatteryClass] && [cursor isKindOfClass:[UIViewController class]])return (UIViewController *)cursor;
        cursor=cursor.nextResponder;
    }
    return nil;
}
// UIApplication state is diagnostic only for this remote UI service. A nil
// scene is allowed for legacy service windows; an explicitly background or
// unattached scene is still rejected. Geometry is not proof of host visibility.
static NSString *axs_headsetcardtimer_visibilityReason(UIView *view,UIWindow *window) {
    if (!view || !window)return @"missing_view_or_window";
    if (view.window!=window)return @"window_mismatch";
    if (window.hidden || window.alpha<=0.01)return @"window_hidden_or_transparent";
    UIWindowScene *scene=window.windowScene;
    if (scene && scene.activationState==UISceneActivationStateBackground)return @"scene_background";
    if (scene && scene.activationState==UISceneActivationStateUnattached)return @"scene_unattached";
    if (CGRectIsEmpty(view.bounds))return @"empty_bounds";
    UIView *cursor=view;
    BOOL attached=NO;
    for (NSUInteger i=0;cursor && i<64;++i) {
        if (cursor.hidden || cursor.alpha<=0.01)return @"view_or_ancestor_hidden";
        if (cursor==window) { attached=YES;break; }
        cursor=cursor.superview;
    }
    if (!attached)return @"not_attached_within_depth_limit";
    CGRect rect=[view convertRect:view.bounds toView:window];
    if (CGRectIsNull(rect) || CGRectIsInfinite(rect) || !CGRectIntersectsRect(rect,window.bounds))return @"outside_window_bounds";
    return nil;
}
static BOOL axs_headsetcardtimer_visible(UIView *view,UIWindow *window) {
    return axs_headsetcardtimer_visibilityReason(view,window)==nil;
}
static void axs_headsetcardtimer_detectionLog(NSString *event,UIView *view,UIViewController *battery,NSString *reason) {
    static NSUInteger count;
    if (count>=80)return;
    ++count;
    UIWindow *window=view.window;
    UIWindowScene *scene=window.windowScene;
    axs_headsetcardtimer_log(event,@{
        @"reason":reason ?: @"eligible",
        @"view_class":view ? NSStringFromClass([view class]) : @"nil",
        @"controller_matched":@(battery!=nil),
        @"has_window":@(window!=nil),
        @"app_state_raw":@([UIApplication sharedApplication].applicationState),
        @"has_scene":@(scene!=nil),
        @"scene_state_raw":scene ? @(scene.activationState) : @(-99),
        @"window_hidden":window ? @(window.hidden) : @YES,
        @"window_alpha":window ? @(window.alpha) : @0,
        @"bounds_empty":view ? @(CGRectIsEmpty(view.bounds)) : @YES
    });
}
// Inspect the full, bounded UIKit containment route. Never dismiss a random
// topmost controller, another service window, a pairing dialog or the service process.
static UIViewController *axs_headsetcardtimer_route(UIViewController *battery,UIWindow *window,NSMutableArray *route,NSString **reason) {
    UIViewController *cursor=battery;
    NSHashTable *seen=[NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    UIViewController *modal=nil;
    for (NSUInteger i=0;cursor && i<8;++i) {
        if ([seen containsObject:cursor]) { *reason=@"controller_cycle";return nil; }
        [seen addObject:cursor];
        NSString *name=NSStringFromClass([cursor class]);
        if (cursor!=battery && ![@[@"PRXNavigationController",@"PRXCardContainerViewController"] containsObject:name]) { *reason=@"unknown_parent_controller";return nil; }
        [route addObject:name];
        if (cursor.isBeingDismissed || cursor.isBeingPresented || cursor.presentedViewController || !cursor.isViewLoaded || !axs_headsetcardtimer_visible(cursor.view,window)) { *reason=@"transition_hidden_or_another_modal";return nil; }
        if (cursor.presentingViewController) {
            UIViewController *presenter=cursor.presentingViewController;
            if (presenter.presentedViewController==cursor)modal=cursor;
        }
        // Stop at the exact card container. A remote service operator may be its
        // parent, but is not a target and is never sent a close request.
        if ([name isEqual:@"PRXCardContainerViewController"]) {
            *reason=modal ? @"local_modal_ancestor" : @"remote_container_public_dismiss_trial";
            return modal ?: cursor;
        }
        UIViewController *parent=cursor.parentViewController;
        if (!parent) {
            if (modal) { *reason=@"local_modal_ancestor";return modal; }
            *reason=@"no_confirmed_card_container";return nil;
        }
        if ([parent isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav=(UINavigationController *)parent;
            if (nav.topViewController!=cursor || nav.visibleViewController!=cursor) { *reason=@"battery_is_not_top_navigation_page";return nil; }
        } else if (![parent.childViewControllers containsObject:cursor] || parent.childViewControllers.count!=1) {
            *reason=@"ambiguous_container_children";return nil;
        }
        cursor=parent;
    }
    *reason=@"controller_depth_limit";return nil;
}
static void axs_headsetcardtimer_attempt(AxsHeadsetCardTimerContext *context) {
    if (![NSThread isMainThread] || !axs_headsetbridge_card_enabled() || !context || context.axs_headsetcardtimer_cancelled || context.axs_headsetcardtimer_attempted)return;
    @try {
        UIView *view=context.axs_headsetcardtimer_view;
        UIViewController *battery=context.axs_headsetcardtimer_battery;
        UIWindow *window=context.axs_headsetcardtimer_window;
        if (!view || !battery || !window || objc_getAssociatedObject(view,&AxsHeadsetCardTimerContextKey)!=context || objc_getAssociatedObject(battery,&AxsHeadsetCardTimerContextKey)!=context || axs_headsetcardtimer_battery(view)!=battery || !axs_headsetcardtimer_visible(view,window)) {
            context.axs_headsetcardtimer_cancelled=YES;
            axs_headsetcardtimer_log(@"timer_cancelled",@{@"reason":@"card_removed_or_replaced"});return;
        }
        if (![NSStringFromClass([battery class]) isEqual:AxsHeadsetCardTimerBatteryClass] || [objc_getAssociatedObject(battery,&AxsHeadsetCardTimerDisappearingKey) boolValue])return;
        NSMutableArray *route=[NSMutableArray array];NSString *reason=@"unknown";
        UIViewController *target=axs_headsetcardtimer_route(battery,window,route,&reason);
        if (!target) {
            context.axs_headsetcardtimer_attempted=YES;
            axs_headsetcardtimer_log(@"dismiss_skipped",@{@"reason":reason,@"controller_route":route,@"elapsed_seconds":@(axs_headsetcardtimer_elapsed(context.axs_headsetcardtimer_started))});return;
        }
        context.axs_headsetcardtimer_attempted=YES;
        axs_headsetcardtimer_log(@"dismiss_requested",@{@"route":reason,@"controller_route":route,@"target_class":NSStringFromClass([target class]),@"elapsed_seconds":@(axs_headsetcardtimer_elapsed(context.axs_headsetcardtimer_started)),@"note":@"A UIKit request, not proof the remote host closed"});
        NSMutableArray *finalRoute=[NSMutableArray array];NSString *finalReason=@"unknown";
        if (context.axs_headsetcardtimer_cancelled || objc_getAssociatedObject(battery,&AxsHeadsetCardTimerContextKey)!=context || axs_headsetcardtimer_battery(view)!=battery || !axs_headsetcardtimer_visible(view,window) || axs_headsetcardtimer_route(battery,window,finalRoute,&finalReason)!=target) {
            axs_headsetcardtimer_log(@"dismiss_aborted",@{@"reason":@"context_changed_before_submission"});return;
        }
        [target dismissViewControllerAnimated:YES completion:^{
            axs_headsetcardtimer_log(@"dismiss_completion",@{@"route":reason,@"note":@"Completion alone is not visibility confirmation"});
        }];
        // One finite read-only check, no repeat close, service kill or hidden-window fallback.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.8*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            @try {
                BOOL stillVisible=axs_headsetcardtimer_visible(context.axs_headsetcardtimer_view,context.axs_headsetcardtimer_window) && context.axs_headsetcardtimer_battery && axs_headsetcardtimer_battery(context.axs_headsetcardtimer_view)==context.axs_headsetcardtimer_battery;
                axs_headsetcardtimer_log(@"dismiss_visibility_check",@{@"same_card_visible":@(stillVisible),@"note":@"UIKit visibility observation, verify actual screen"});
            } @catch(NSException *e) { (void)e; }
        });
    } @catch(NSException *e) {
        context.axs_headsetcardtimer_attempted=YES;
        axs_headsetcardtimer_log(@"dismiss_exception",@{@"name":e.name});
    }
}
static void axs_headsetcardtimer_viewMoved(UIView *view) {
    if (![NSThread isMainThread] || !axs_headsetbridge_card_enabled())return;
    AxsHeadsetCardTimerContext *old=objc_getAssociatedObject(view,&AxsHeadsetCardTimerContextKey);
    UIViewController *battery=view.window ? axs_headsetcardtimer_battery(view) : nil;
    if (old && view.window && view.window==old.axs_headsetcardtimer_window && battery==old.axs_headsetcardtimer_battery && !old.axs_headsetcardtimer_cancelled)return; // no deadline renewal on layout
    if (old) {
        old.axs_headsetcardtimer_cancelled=YES;
        if (old.axs_headsetcardtimer_battery && objc_getAssociatedObject(old.axs_headsetcardtimer_battery,&AxsHeadsetCardTimerContextKey)==old) objc_setAssociatedObject(old.axs_headsetcardtimer_battery,&AxsHeadsetCardTimerContextKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(view,&AxsHeadsetCardTimerContextKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!view.window || !battery) {
        axs_headsetcardtimer_detectionLog(@"candidate_rejected",view,battery,view.window ? @"exact_battery_not_in_responder_chain" : @"no_window");return;
    }
    if ([objc_getAssociatedObject(battery,&AxsHeadsetCardTimerDisappearingKey) boolValue]) {
        axs_headsetcardtimer_detectionLog(@"candidate_rejected",view,battery,@"battery_disappearing");return;
    }
    axs_headsetcardtimer_installLifecycle();
    if (!AxsHeadsetCardTimerObservedViews)AxsHeadsetCardTimerObservedViews=[NSHashTable weakObjectsHashTable];
    [AxsHeadsetCardTimerObservedViews addObject:view];
    NSString *rejection=axs_headsetcardtimer_visibilityReason(view,view.window);
    if (rejection) { axs_headsetcardtimer_detectionLog(@"candidate_rejected",view,battery,rejection);return; }
    AxsHeadsetCardTimerContext *existing=objc_getAssociatedObject(battery,&AxsHeadsetCardTimerContextKey);
    if (existing && !existing.axs_headsetcardtimer_cancelled && existing.axs_headsetcardtimer_window==view.window && (existing.axs_headsetcardtimer_attempted || axs_headsetcardtimer_visible(existing.axs_headsetcardtimer_view,existing.axs_headsetcardtimer_window)))return;
    if (existing)existing.axs_headsetcardtimer_cancelled=YES;
    const NSTimeInterval AxsHeadsetCardTimerDelay=axs_headsetbridge_card_delay();
    AxsHeadsetCardTimerContext *context=[AxsHeadsetCardTimerContext new];
    context.axs_headsetcardtimer_view=view;context.axs_headsetcardtimer_window=view.window;context.axs_headsetcardtimer_battery=battery;context.axs_headsetcardtimer_started=mach_absolute_time();
    objc_setAssociatedObject(view,&AxsHeadsetCardTimerContextKey,context,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(battery,&AxsHeadsetCardTimerContextKey,context,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    axs_headsetcardtimer_detectionLog(@"candidate_accepted",view,battery,nil);
    axs_headsetcardtimer_log(@"battery_card_detected",@{@"controller_class":NSStringFromClass([battery class]),@"delay_seconds":@(AxsHeadsetCardTimerDelay),@"note":@"Measured from eligible content entering a visible window, not exact animation completion"});
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(AxsHeadsetCardTimerDelay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{axs_headsetcardtimer_attempt(context);});
}
static void axs_headsetcardtimer_cancelBattery(UIViewController *battery) {
    AxsHeadsetCardTimerContext *context=objc_getAssociatedObject(battery,&AxsHeadsetCardTimerContextKey);
    if (!context)return;
    context.axs_headsetcardtimer_cancelled=YES;
    if (context.axs_headsetcardtimer_view && objc_getAssociatedObject(context.axs_headsetcardtimer_view,&AxsHeadsetCardTimerContextKey)==context) objc_setAssociatedObject(context.axs_headsetcardtimer_view,&AxsHeadsetCardTimerContextKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(battery,&AxsHeadsetCardTimerContextKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void axs_headsetcardtimer_appear(UIViewController *controller,SEL selector,BOOL animated) {
    AxsHeadsetCardTimerOriginalAppear(controller,selector,animated);
    @try {
        if (![NSThread isMainThread] || ![NSStringFromClass([controller class]) isEqual:AxsHeadsetCardTimerBatteryClass])return;
        axs_headsetcardtimer_log(@"battery_did_appear",@{@"app_state_raw":@([UIApplication sharedApplication].applicationState)});
        objc_setAssociatedObject(controller,&AxsHeadsetCardTimerDisappearingKey,@NO,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // New appearance is a new generation even if UIKit reuses the controller.
        axs_headsetcardtimer_cancelBattery(controller);
        for (UIView *view in AxsHeadsetCardTimerObservedViews.allObjects) {
            if (axs_headsetcardtimer_battery(view)==controller)axs_headsetcardtimer_viewMoved(view);
        }
        // A pre-existing card need not have passed through our move callback.
        axs_headsetcardtimer_eventDiscovery(@"exact_battery_did_appear",controller);
    } @catch(NSException *e) { (void)e; }
}
static void axs_headsetcardtimer_disappear(UIViewController *controller,SEL selector,BOOL animated) {
    @try {
        if ([NSThread isMainThread] && [NSStringFromClass([controller class]) isEqual:AxsHeadsetCardTimerBatteryClass]) {
            objc_setAssociatedObject(controller,&AxsHeadsetCardTimerDisappearingKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            axs_headsetcardtimer_cancelBattery(controller);
            axs_headsetcardtimer_log(@"battery_will_disappear",@{});
        }
    } @catch(NSException *e) { (void)e; }
    AxsHeadsetCardTimerOriginalDisappear(controller,selector,animated);
}
static void axs_headsetcardtimer_installLifecycle(void) {
    static BOOL installed;
    if (installed || ![NSThread isMainThread])return;
    Class cls=NSClassFromString(AxsHeadsetCardTimerBatteryClass);
    if (!cls || ![cls isSubclassOfClass:[UIViewController class]])return;
    Method appear=class_getInstanceMethod(cls,@selector(viewDidAppear:));
    Method disappear=class_getInstanceMethod(cls,@selector(viewWillDisappear:));
    char ar[8]={0},dr[8]={0},aa[8]={0},da[8]={0};
    if (!appear || !disappear)return;
    method_getReturnType(appear,ar,sizeof(ar));method_getReturnType(disappear,dr,sizeof(dr));
    method_getArgumentType(appear,2,aa,sizeof(aa));method_getArgumentType(disappear,2,da,sizeof(da));
    if (method_getNumberOfArguments(appear)!=3 || method_getNumberOfArguments(disappear)!=3 || strcmp(ar,"v") || strcmp(dr,"v") || strcmp(aa,"B") || strcmp(da,"B"))return;
    MSHookMessageEx(cls,@selector(viewDidAppear:),(IMP)axs_headsetcardtimer_appear,(IMP *)&AxsHeadsetCardTimerOriginalAppear);
    MSHookMessageEx(cls,@selector(viewWillDisappear:),(IMP)axs_headsetcardtimer_disappear,(IMP *)&AxsHeadsetCardTimerOriginalDisappear);
    installed=YES;
    axs_headsetcardtimer_log(@"battery_lifecycle_hooked",@{@"class":AxsHeadsetCardTimerBatteryClass});
}
static void axs_headsetcardtimer_move(UIView *view,SEL selector) {
    // Original UIKit callback exactly once. Never swallow the original exception.
    AxsHeadsetCardTimerOriginalMove(view,selector);
    @try {
        static NSUInteger callbackReports;
        if ([NSThread isMainThread] && callbackReports++<16) axs_headsetcardtimer_detectionLog(@"content_move_callback",view,axs_headsetcardtimer_battery(view),nil);
        axs_headsetcardtimer_viewMoved(view);
        __weak UIView *weakView=view;
        // Recheck hierarchy/scene/layout once after this callback; no polling.
        dispatch_async(dispatch_get_main_queue(),^{
            @try { if (weakView)axs_headsetcardtimer_viewMoved(weakView); }
            @catch(NSException *e) { (void)e; }
        });
    } @catch(NSException *e) { axs_headsetcardtimer_log(@"observer_exception",@{@"name":e.name}); }
}
static void axs_headsetcardtimer_discover(NSString *stage,UIViewController *hint) {
    if (![NSThread isMainThread])return;
    static BOOL scanning;
    if (scanning)return;
    scanning=YES;
    @try {
        NSMutableOrderedSet *roots=[NSMutableOrderedSet orderedSet];
        NSUInteger windowCount=0;
        BOOL windowLimit=NO;
        // Legacy remote-service windows can lack a UIWindowScene. Keep this
        // fallback alongside scene.windows; suppress only this deprecated read.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray<UIWindow *> *axs_headsetcardtimer_legacyWindows=[UIApplication sharedApplication].windows;
#pragma clang diagnostic pop
        for (UIWindow *window in axs_headsetcardtimer_legacyWindows) {
            if (++windowCount>16) { windowLimit=YES;break; }
            [roots addObject:window];
        }
        if (!windowLimit) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]])continue;
                for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                    if ([roots containsObject:window])continue;
                    if (++windowCount>16) { windowLimit=YES;break; }
                    [roots addObject:window];
                }
                if (windowLimit)break;
            }
        }
        // Exact lifecycle hint covers a remote-service root not listed by UIApplication.
        if (hint && [NSStringFromClass([hint class]) isEqual:AxsHeadsetCardTimerBatteryClass] && hint.isViewLoaded && hint.view.window) {
            UIWindow *hintWindow=hint.view.window;
            if ([roots containsObject:hintWindow]) [roots addObject:hint.view];
            else if (windowCount<16) { ++windowCount;[roots addObject:hint.view]; }
            else windowLimit=YES;
        }
        NSMutableArray *stack=[roots.array mutableCopy];
        NSHashTable *seen=[NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
        Class contentClass=NSClassFromString(@"PRXCardContentView");
        NSUInteger visited=0,candidates=0,batteries=0;
        BOOL viewLimit=NO;
        while (stack.count && visited<2048) {
            UIView *view=stack.lastObject;
            [stack removeLastObject];
            if ([seen containsObject:view])continue;
            [seen addObject:view];++visited;
            if (contentClass && [view isKindOfClass:contentClass]) {
                ++candidates;
                if (axs_headsetcardtimer_battery(view))++batteries;
                axs_headsetcardtimer_viewMoved(view);
            }
            NSUInteger occupied=visited+stack.count;
            NSUInteger remaining=occupied<2048 ? 2048-occupied : 0;
            for (UIView *child in view.subviews) {
                if (!remaining) { viewLimit=YES;break; }
                [stack addObject:child];--remaining;
            }
        }
        static NSUInteger reports;
        if (reports<20) {
            ++reports;
            axs_headsetcardtimer_log(@"discovery_summary",@{@"stage":stage,@"window_count":@(MIN(windowCount,(NSUInteger)16)),@"views_visited":@(visited),@"content_candidates":@(candidates),@"exact_battery_matches":@(batteries),@"scan_truncated":@(windowLimit || viewLimit || stack.count>0 || visited>=2048),@"note":@"Local service view discovery only, no UI text read or unknown controller dismissal"});
        }
    } @catch(NSException *e) { axs_headsetcardtimer_log(@"discovery_exception",@{@"name":e.name}); }
    @finally { scanning=NO; }
}
static void axs_headsetcardtimer_eventDiscovery(NSString *stage,UIViewController *hint) {
    // No continuous sweep. After startup, only finite windows per actual event;
    // cap global discovery bursts while per-view/lifecycle hooks keep working.
    static NSUInteger bursts;
    if (bursts>=12)return;
    ++bursts;
    axs_headsetcardtimer_discover(stage,hint);
    __weak UIViewController *weakHint=hint;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.35*NSEC_PER_SEC)),dispatch_get_main_queue(),^{axs_headsetcardtimer_discover(stage,weakHint);});
}
void axs_headsetcardtimer_start(void) {
    if (![NSThread isMainThread])return;
    static BOOL installed;
    static BOOL observersInstalled;
    static NSUInteger checks;
    @try {
        NSProcessInfo *process=[NSProcessInfo processInfo];
        NSOperatingSystemVersion os=process.operatingSystemVersion;
        if (![process.processName isEqual:@"SharingViewService"] || os.majorVersion!=16 || checks>=3)return;
        ++checks;
        if (!installed) {
            Class cls=NSClassFromString(@"PRXCardContentView");
            Method method=cls ? class_getInstanceMethod(cls,@selector(didMoveToWindow)) : NULL;
            char result[16]={0};if(method)method_getReturnType(method,result,sizeof(result));
            if (cls && [cls isSubclassOfClass:[UIView class]] && method && method_getNumberOfArguments(method)==2 && strcmp(result,"v")==0) {
                MSHookMessageEx(cls,@selector(didMoveToWindow),(IMP)axs_headsetcardtimer_move,(IMP *)&AxsHeadsetCardTimerOriginalMove);
                installed=YES;
                axs_headsetcardtimer_log(@"hook_installed",@{@"view_class":@"PRXCardContentView",@"target_controller":AxsHeadsetCardTimerBatteryClass,@"delay_seconds":@(axs_headsetbridge_card_delay()),@"system":process.operatingSystemVersionString});
            } else axs_headsetcardtimer_log(@"hook_not_ready",@{@"class_loaded":@(cls!=Nil),@"check":@(checks)});
        }
        axs_headsetcardtimer_installLifecycle();
        if (!observersInstalled) {
            observersInstalled=YES;
            NSNotificationCenter *center=[NSNotificationCenter defaultCenter];
            [center addObserverForName:UISceneDidEnterBackgroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note){
                @try {
                    for (UIView *view in AxsHeadsetCardTimerObservedViews.allObjects) {
                        if (view.window.windowScene==note.object) {
                            UIViewController *battery=axs_headsetcardtimer_battery(view);
                            if (battery)axs_headsetcardtimer_cancelBattery(battery);
                        }
                    }
                } @catch(NSException *e) { (void)e; }
            }];
            for (NSString *name in @[UIApplicationDidBecomeActiveNotification,UISceneDidActivateNotification,UIWindowDidBecomeVisibleNotification]) {
                [center addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note){
                    dispatch_async(dispatch_get_main_queue(),^{axs_headsetcardtimer_eventDiscovery(note.name,nil);});
                }];
            }
        }
        // Each of the three startup checks also inspects already existing windows.
        axs_headsetcardtimer_discover([NSString stringWithFormat:@"startup_%lu",(unsigned long)checks],nil);
    } @catch(NSException *e) { axs_headsetcardtimer_log(@"install_exception",@{@"name":e.name}); }
}

// Disable only cancels this module's pending contexts. No music notification,
// active playback, media command or service restart is issued.
void axs_headsetcardtimer_configChanged(void) {
    if (![NSThread isMainThread] || axs_headsetbridge_card_enabled())return;
    for (UIView *view in AxsHeadsetCardTimerObservedViews.allObjects) {
        AxsHeadsetCardTimerContext *context=objc_getAssociatedObject(view,&AxsHeadsetCardTimerContextKey);
        if (context)context.axs_headsetcardtimer_cancelled=YES;
        UIViewController *battery=axs_headsetcardtimer_battery(view);
        if (battery)axs_headsetcardtimer_cancelBattery(battery);
    }
}
