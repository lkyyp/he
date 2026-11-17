#pragma once

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdint.h>
#import <stdlib.h>
#import "AxsHeadsetBridgePaths.h"

static NSString * const AxsHeadsetBridgePreferencesDomain = @"com.axs.headsetbridge";
static NSString * const AxsHeadsetBridgePreferencesChanged = @"com.axs.headsetbridge.preferences-changed";

static inline NSDictionary *axs_headsetbridge_readPreferences(void) {
    NSString *path = axs_headsetbridge_preferencesPath();
    NSDictionary *values = path.length > 0 ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    if ([values isKindOfClass:[NSDictionary class]]) {
        return values;
    }
    // A missing, unreadable or malformed canonical file fails closed.
    // Runtime never migrates or writes standalone-plugin preferences.
    return @{};
}

// The PreferenceBundle is the only caller allowed to write.
static inline BOOL axs_headsetbridge_writePreference(NSString *key, id value, NSError **error) {
    NSString *path = axs_headsetbridge_preferencesPath();
    if (key.length == 0 || path.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:AxsHeadsetBridgePreferencesDomain code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"Invalid preference path or key"}];
        }
        return NO;
    }
    NSFileManager *manager = [NSFileManager defaultManager];
    NSMutableDictionary *values;
    if ([manager fileExistsAtPath:path]) {
        NSData *existing = [NSData dataWithContentsOfFile:path options:0 error:error];
        id decoded = existing ? [NSPropertyListSerialization propertyListWithData:existing
                         options:NSPropertyListMutableContainers format:NULL error:error] : nil;
        if (![decoded isKindOfClass:[NSDictionary class]]) {
            if (error && !*error) {
                *error = [NSError errorWithDomain:AxsHeadsetBridgePreferencesDomain code:2
                                        userInfo:@{NSLocalizedDescriptionKey: @"Preferences are not a dictionary"}];
            }
            return NO;
        }
        values = [decoded mutableCopy];
    } else {
        values = [axs_headsetbridge_readPreferences() mutableCopy];
    }
    if (![key isEqual:@"enabled"] && ![key isEqual:@"selectedApp"]) return NO;
    if ([key isEqual:@"enabled"] && ![value isKindOfClass:[NSNumber class]]) return NO;
    if ([key isEqual:@"selectedApp"] && ![@[@"cloud", @"kuwo"] containsObject:value]) return NO;
    if (value) values[key] = value;
    else [values removeObjectForKey:key];
    // Persist the complete target/enabled/epoch snapshot, never separate updates.
    if (!values[@"enabled"]) values[@"enabled"] = @NO;
    if (!values[@"selectedApp"]) values[@"selectedApp"] = @"cloud";
    if (![values[@"enabled"] isKindOfClass:[NSNumber class]] || ![@[@"cloud", @"kuwo"] containsObject:values[@"selectedApp"]] || (values[@"selectionEpoch"] && ![values[@"selectionEpoch"] isKindOfClass:[NSNumber class]])) {
        if (error) *error = [NSError errorWithDomain:AxsHeadsetBridgePreferencesDomain code:3 userInfo:@{NSLocalizedDescriptionKey:@"配置字段格式错误，未覆盖原文件。"}];
        return NO;
    }
    uint64_t previousEpoch = [values[@"selectionEpoch"] unsignedLongLongValue];
    uint64_t epoch = ((uint64_t)arc4random() << 32) | arc4random();
    if (!epoch || epoch == previousEpoch) epoch = previousEpoch + 1;
    if (!epoch) epoch = 1;
    values[@"selectionEpoch"] = @(epoch);
    if (![manager createDirectoryAtPath:[path stringByDeletingLastPathComponent]
            withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:values
                         format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error]) {
        return NO;
    }
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:AxsHeadsetBridgePreferencesDomain];
    // Mirror the whole snapshot so cfprefsd cannot flush stale unrelated keys.
    [defaults setPersistentDomain:values forName:AxsHeadsetBridgePreferencesDomain];
    [defaults synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)AxsHeadsetBridgePreferencesChanged, NULL, NULL, true);
    return YES;
}
