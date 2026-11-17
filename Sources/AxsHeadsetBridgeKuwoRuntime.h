#pragma once
#import <Foundation/Foundation.h>
#import "AxsHeadsetBridgeGate.h"

#ifdef __cplusplus
extern "C" {
#endif

void axs_headsetbridge_kuwo_log(NSString *event, NSDictionary *fields);
void axs_headsetbridge_kuwo_startSpringBoard(void);
void axs_headsetbridge_kuwo_startMusic(void);
void axs_headsetbridge_kuwo_signalMusic(void);
void axs_headsetbridge_kuwo_startPlayback(void);
void axs_headsetbridge_kuwo_tryPlayback(uint64_t requestState);
NSString *axs_headsetbridge_kuwo_logPath(void);
void axs_headsetbridge_kuwo_observeProcesses(uint32_t session, NSString *stage);
void axs_headsetbridge_kuwo_collectSystemInterfaces(void);
void axs_headsetbridge_kuwo_startBackground(void);
void axs_headsetbridge_kuwo_reconcileBackground(NSString *stage);
void axs_headsetbridge_kuwo_backgroundConsumed(uint64_t lease, BOOL forPlayback);
void axs_headsetbridge_kuwo_backgroundFinish(uint64_t lease, NSString *reason);

#ifdef __cplusplus
}
#endif

#define AxsHeadsetBridgeKuwoRequest "com.axs.headsetbridge.kuwo.request"
#define AxsHeadsetBridgeKuwoAck "com.axs.headsetbridge.kuwo.ack"

#define AxsHeadsetBridgeKuwoLease "com.axs.headsetbridge.kuwo.playback-lease-v3"
// uint64 lease = sessionNonce:32 | expiration(systemUptime seconds):32.
// It prevents stale requests, NOT an authentication boundary on a jailbroken phone.

#define AxsHeadsetBridgeKuwoConsumed "com.axs.headsetbridge.kuwo.consumed-session-v3"
