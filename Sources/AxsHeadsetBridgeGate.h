#pragma once
#import <Foundation/Foundation.h>
#ifdef __cplusplus
extern "C" {
#endif
void axs_headsetbridge_startGate(void);
BOOL axs_headsetbridge_enabledFor(NSString *engine);
NSString *axs_headsetbridge_selectedBundle(void);
uint64_t axs_headsetbridge_configurationEpoch(void);
BOOL axs_headsetbridge_publishBinding(NSString *engine, uint64_t lease, uint64_t expectedEpoch);
BOOL axs_headsetbridge_bindingValid(NSString *engine, uint64_t lease);
BOOL axs_headsetbridge_revokeBinding(NSString *engine);
void axs_headsetbridge_engineLog(NSString *engine, NSString *event, NSDictionary *fields);
#ifdef __cplusplus
}
#endif
