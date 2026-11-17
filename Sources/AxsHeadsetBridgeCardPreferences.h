#pragma once
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>
#import "AxsHeadsetBridgePaths.h"

static NSString *const AxsHeadsetBridgeCardDomain=@"com.axs.headsetbridge.card";
static NSString *const AxsHeadsetBridgeCardChanged=@"com.axs.headsetbridge.card.preferences-changed";
static inline NSString *axs_headsetbridge_card_preferencesPath(void) {
    NSString *path=@"/var/mobile/Library/Preferences/com.axs.headsetbridge.card.plist";
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
    return jbroot(path);
#else
    return path;
#endif
}
static inline NSInteger axs_headsetbridge_card_seconds(id value) {
    if (![value isKindOfClass:[NSNumber class]] || !isfinite([value doubleValue]))return 5;
    return (NSInteger)round(fmax(3.0,fmin(50.0,[value doubleValue])));
}
static inline NSDictionary *axs_headsetbridge_card_readPreferences(void) {
    NSDictionary *d=[NSDictionary dictionaryWithContentsOfFile:axs_headsetbridge_card_preferencesPath()];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}
// Only the card settings controller writes this file. No music preference path,
// selectionEpoch or music notification is touched by a card adjustment.
static inline BOOL axs_headsetbridge_card_writePreference(NSString *key,id value,NSError **error) {
    if (![@[@"cardEnabled",@"cardSeconds"] containsObject:key])return NO;
    if (![value isKindOfClass:[NSNumber class]] || !isfinite([value doubleValue]))return NO;
    NSString *path=axs_headsetbridge_card_preferencesPath();
    NSFileManager *fm=[NSFileManager defaultManager];
    NSMutableDictionary *values=[NSMutableDictionary dictionary];
    if ([fm fileExistsAtPath:path]) {
        NSData *data=[NSData dataWithContentsOfFile:path options:0 error:error];
        id decoded=data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:error] : nil;
        if (![decoded isKindOfClass:[NSDictionary class]]) {
            if (error && !*error)*error=[NSError errorWithDomain:AxsHeadsetBridgeCardDomain code:1 userInfo:@{NSLocalizedDescriptionKey:@"弹窗配置无法读取，未覆盖原文件。"}];
            return NO;
        }
        values=[decoded mutableCopy];
    }
    values[key]=[key isEqual:@"cardSeconds"] ? @(axs_headsetbridge_card_seconds(value)) : @([value boolValue]);
    if (!values[@"cardEnabled"])values[@"cardEnabled"]=@YES;
    if (!values[@"cardSeconds"])values[@"cardSeconds"]=@5;
    if (![values[@"cardEnabled"] isKindOfClass:[NSNumber class]] || ![values[@"cardSeconds"] isKindOfClass:[NSNumber class]] || !isfinite([values[@"cardSeconds"] doubleValue]))return NO;
    values[@"cardSeconds"]=@(axs_headsetbridge_card_seconds(values[@"cardSeconds"]));
    if (![fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error])return NO;
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:values format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error])return NO;
    NSUserDefaults *defaults=[[NSUserDefaults alloc] initWithSuiteName:AxsHeadsetBridgeCardDomain];
    [defaults setPersistentDomain:values forName:AxsHeadsetBridgeCardDomain];
    [defaults synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),(__bridge CFStringRef)AxsHeadsetBridgeCardChanged,NULL,NULL,true);
    return YES;
}
