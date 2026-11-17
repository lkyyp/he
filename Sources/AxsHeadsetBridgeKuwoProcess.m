#import "AxsHeadsetBridgeKuwoRuntime.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <stdint.h>
#import <string.h>

// ABI: Apple xnu libsyscall/wrappers/libproc/libproc.h (see evidence).
// No signals, process writes, task ports, assertions or application activation.
static int (*AxsHeadsetBridgeKuwoListPIDs)(void *, int);
static int (*AxsHeadsetBridgeKuwoPIDPath)(int, void *, uint32_t);
static dispatch_queue_t AxsHeadsetBridgeKuwoProcessQueue;

static void axs_headsetbridge_kuwo_processSetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AxsHeadsetBridgeKuwoProcessQueue = dispatch_queue_create("com.axs.headsetbridge.kuwo.process-observation", DISPATCH_QUEUE_SERIAL);
        void *handle = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY | RTLD_LOCAL);
        if (handle) {
            AxsHeadsetBridgeKuwoListPIDs = (int (*)(void *, int))dlsym(handle, "proc_listallpids");
            AxsHeadsetBridgeKuwoPIDPath = (int (*)(int, void *, uint32_t))dlsym(handle, "proc_pidpath");
        }
    });
}

void axs_headsetbridge_kuwo_observeProcesses(uint32_t session, NSString *stage) {
    axs_headsetbridge_kuwo_processSetup();
    NSTimeInterval scheduled = [NSProcessInfo processInfo].systemUptime;
    dispatch_async(AxsHeadsetBridgeKuwoProcessQueue, ^{
        @autoreleasepool {
            int *pids = NULL;
            @try {
                NSTimeInterval started = [NSProcessInfo processInfo].systemUptime;
                NSMutableDictionary *row = [@{@"session": @(session), @"stage": stage, @"scheduled_uptime": @(scheduled), @"scan_started_uptime": @(started), @"pid_list_api": @(AxsHeadsetBridgeKuwoListPIDs != NULL), @"pid_path_api": @(AxsHeadsetBridgeKuwoPIDPath != NULL), @"note": @"Kernel/path observation only. A matching PID does not prove scheduled/runnable. No matches does not prove absence when access is incomplete."} mutableCopy];
                if (!AxsHeadsetBridgeKuwoListPIDs || !AxsHeadsetBridgeKuwoPIDPath) { row[@"status"] = @"api_unavailable"; axs_headsetbridge_kuwo_log(@"sb.process_observation", row); return; }
                int needed = AxsHeadsetBridgeKuwoListPIDs(NULL, 0);
                if (needed <= 0) { row[@"status"] = @"pid_list_failed"; axs_headsetbridge_kuwo_log(@"sb.process_observation", row); return; }
                NSUInteger capacity = MIN((NSUInteger)needed + 128, (NSUInteger)4096);
                pids = calloc(capacity, sizeof(int));
                if (!pids) { row[@"status"] = @"allocation_failed"; axs_headsetbridge_kuwo_log(@"sb.process_observation", row); return; }
                int got = AxsHeadsetBridgeKuwoListPIDs(pids, (int)(capacity * sizeof(int)));
                NSMutableArray *matches = [NSMutableArray array];
                NSUInteger pathDenied = 0, appInfoFailed = 0, examined = 0;
                if (got > 0) {
                    for (NSUInteger i = 0; i < MIN((NSUInteger)got, capacity); ++i) {
                        if (pids[i] <= 0) continue;
                        ++examined;
                        char pathBuffer[4096] = {0};
                        int length = AxsHeadsetBridgeKuwoPIDPath(pids[i], pathBuffer, (uint32_t)sizeof(pathBuffer));
                        if (length <= 0 || !memchr(pathBuffer, 0, sizeof(pathBuffer))) { ++pathDenied; continue; }
                        NSString *executable = [NSString stringWithUTF8String:pathBuffer];
                        if (!executable) { ++pathDenied; continue; }
                        // Only inspect Info.plist beside a main .app executable; no app/user data files.
                        NSString *appDirectory = executable.stringByDeletingLastPathComponent;
                        if (![appDirectory.pathExtension isEqual:@"app"]) continue;
                        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appDirectory stringByAppendingPathComponent:@"Info.plist"]];
                        if (!info) { ++appInfoFailed; continue; }
                        if (![info[@"CFBundleIdentifier"] isEqual:@"com.yeelion.kwplayer"]) continue;
                        NSString *declaredExecutable = info[@"CFBundleExecutable"];
                        if (![declaredExecutable isKindOfClass:[NSString class]] || ![declaredExecutable isEqual:executable.lastPathComponent]) continue;
                        [matches addObject:@{@"pid": @(pids[i]), @"bundle_verified_from_app_info": @YES}];
                    }
                }
                free(pids); pids = NULL;
                row[@"status"] = got > 0 ? @"scan_completed" : @"pid_list_failed";
                row[@"listed_pid_count"] = @(MAX(got, 0));
                row[@"capacity"] = @(capacity);
                row[@"list_may_be_truncated"] = @(got >= (int)capacity || needed >= (int)capacity);
                row[@"examined"] = @(examined);
                row[@"unresolved_paths"] = @(pathDenied);
                row[@"unreadable_app_info"] = @(appInfoFailed);
                row[@"matching_main_processes"] = matches;
                row[@"scan_finished_uptime"] = @([NSProcessInfo processInfo].systemUptime);
                axs_headsetbridge_kuwo_log(@"sb.process_observation", row);
            } @catch (NSException *exception) { axs_headsetbridge_kuwo_log(@"sb.process_observation_exception", @{@"session": @(session), @"stage": stage, @"name": exception.name}); }
            @finally { free(pids); }
        }
    });
}

static NSArray *axs_headsetbridge_kuwo_systemMethods(Class cls, BOOL meta, NSUInteger *budget, BOOL *truncated) {
    unsigned int count = 0;
    Method *list = class_copyMethodList(meta ? object_getClass(cls) : cls, &count);
    NSUInteger limit = MIN((NSUInteger)count, MIN((NSUInteger)240, *budget));
    *truncated = count > limit;
    @try {
    NSMutableArray *out = [NSMutableArray array];
    // Prefer process/launch selectors if a large system class exceeds the detail cap.
    for (NSUInteger pass = 0; pass < 2 && out.count < limit; ++pass) {
        for (NSUInteger i = 0; i < count && out.count < limit; ++i) {
            NSString *selector = NSStringFromSelector(method_getName(list[i]));
            NSString *lower = selector.lowercaseString;
            BOOL relevant = NO;
            for (NSString *word in @[@"process", @"application", @"launch", @"suspend", @"resume", @"assert", @"running", @"state", @"shared", @"identifier", @"bundle", @"pid"]) {
                if ([lower containsString:word]) { relevant = YES; break; }
            }
            if (relevant != (pass == 0)) continue;
            const char *encoding = method_getTypeEncoding(list[i]);
            [out addObject:@{@"kind": meta ? @"+" : @"-", @"selector": selector, @"encoding": encoding ? [NSString stringWithUTF8String:encoding] : @""}];
        }
    }
    *budget -= out.count;
    return out;
    } @finally { free(list); }
}

void axs_headsetbridge_kuwo_collectSystemInterfaces(void) {
    axs_headsetbridge_kuwo_processSetup();
    dispatch_async(AxsHeadsetBridgeKuwoProcessQueue, ^{
        @autoreleasepool {
            @try {
                NSArray *names = @[@"SpringBoard", @"UIApplication", @"SBApplicationController", @"SBApplication", @"FBApplicationProcess", @"FBProcess", @"FBProcessManager", @"FBSSystemService", @"FBSOpenApplicationService", @"FBSOpenApplicationOptions", @"FBSProcessHandle", @"BSProcessHandle", @"RBSProcessHandle", @"RBSAssertion", @"RBSProcessIdentity", @"RBSProcessState", @"RBSProcessStateDescriptor", @"RBSProcessStateUpdate"];
                NSMutableArray *results = [NSMutableArray array], *missing = [NSMutableArray array];
                NSUInteger budget = 16000;
                for (NSString *name in names) {
                    Class cls = objc_getClass(name.UTF8String);
                    if (!cls) { [missing addObject:name]; continue; }
                    NSMutableArray *hierarchy = [NSMutableArray array];
                    Class cursor = cls;
                    for (NSUInteger depth = 0; cursor && cursor != [NSObject class] && depth < 3; ++depth) {
                        BOOL instanceCut = NO, classCut = NO;
                        NSArray *instance = axs_headsetbridge_kuwo_systemMethods(cursor, NO, &budget, &instanceCut);
                        NSArray *meta = axs_headsetbridge_kuwo_systemMethods(cursor, YES, &budget, &classCut);
                        Class parent = class_getSuperclass(cursor);
                        [hierarchy addObject:@{@"class": NSStringFromClass(cursor), @"superclass": parent ? NSStringFromClass(parent) : @"", @"instance_methods": instance, @"class_methods": meta, @"instance_methods_truncated": @(instanceCut), @"class_methods_truncated": @(classCut)}];
                        cursor = parent;
                    }
                    [results addObject:@{@"class": name, @"hierarchy": hierarchy, @"hierarchy_truncated": @(cursor && cursor != [NSObject class])}];
                }
                NSDictionary *report = @{@"diagnostic_revision": @8, @"experiment": @"kuwo-1200-bounded-preparation-trial", @"system": [NSProcessInfo processInfo].operatingSystemVersionString, @"pid": @([NSProcessInfo processInfo].processIdentifier), @"time": @([NSDate date].timeIntervalSince1970), @"uptime": @([NSProcessInfo processInfo].systemUptime), @"classes": results, @"missing_classes": missing, @"method_budget_remaining": @(budget), @"limits": @{@"methods_per_kind": @240, @"total_methods": @16000, @"hierarchy_depth": @3}, @"note": @"System class metadata only, no method invocation or objects. Availability/encoding does not establish wake semantics or entitlements."};
                NSError *error = nil;
                NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
                NSString *path = @"/var/mobile/Library/Logs/HeadsetBridge-kuwo-system-runtime.json";
                BOOL backupOK = YES;
                if (data && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
                    NSData *previous = [NSData dataWithContentsOfFile:path options:0 error:&error];
                    backupOK = previous && [previous writeToFile:[path stringByAppendingString:@".previous"] options:NSDataWritingAtomic error:&error];
                }
                BOOL written = data && backupOK && [data writeToFile:path options:NSDataWritingAtomic error:&error];
                axs_headsetbridge_kuwo_log(@"sb.system_interfaces_written", @{@"written": @(written), @"backup_ok": @(backupOK), @"error_code": @(error.code), @"classes": @(results.count), @"missing_count": @(missing.count)});
            } @catch (NSException *e) { axs_headsetbridge_kuwo_log(@"sb.system_interfaces_exception", @{@"name": e.name}); }
        }
    });
}
