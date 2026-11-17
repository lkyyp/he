#pragma once
#import <Foundation/Foundation.h>
#import <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef NS_ENUM(NSUInteger, AxsHeadsetBridgeKuwoProfileKind) {
    AxsHeadsetBridgeKuwoProfileCanonical,
    AxsHeadsetBridgeKuwoProfileRelay,
    AxsHeadsetBridgeKuwoProfileSnapshot,
    AxsHeadsetBridgeKuwoProfileLockWait,
    AxsHeadsetBridgeKuwoProfileBinding,
    AxsHeadsetBridgeKuwoProfileStartupGate,
    AxsHeadsetBridgeKuwoProfileKindCount
};
void axs_headsetbridge_kuwo_diagnosticsStart(void);
uint64_t axs_headsetbridge_kuwo_profileBegin(void);
double axs_headsetbridge_kuwo_profileClockSeconds(void);
void axs_headsetbridge_kuwo_profileEnd(AxsHeadsetBridgeKuwoProfileKind kind, uint64_t started, BOOL failed);
void axs_headsetbridge_kuwo_profileReport(NSString *stage, uint64_t requestState);
void axs_headsetbridge_kuwo_recordPlayerState(id manager, id player, id item, id center, uint64_t lease, NSString *stage);
#ifdef __cplusplus
}
#endif
