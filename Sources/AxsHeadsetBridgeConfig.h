#pragma once

#import <Foundation/Foundation.h>

@interface AxsHeadsetBridgeConfig : NSObject
+ (instancetype)axs_headsetbridge_shared;
- (BOOL)axs_headsetbridge_isEnabled;
- (id)axs_headsetbridge_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)axs_headsetbridge_reload;
@end
