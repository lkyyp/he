#pragma once
#import <Foundation/Foundation.h>
#import "AxsHeadsetBridgeGate.h"

#ifdef __cplusplus
extern "C" {
#endif

void axs_headsetbridge_cloud_log(NSString *event, NSDictionary *fields);
void axs_headsetbridge_cloud_startSpringBoard(void);
void axs_headsetbridge_cloud_startMusic(void);
void axs_headsetbridge_cloud_signalMusic(void);
void axs_headsetbridge_cloud_startPlayback(void);
void axs_headsetbridge_cloud_tryPlayback(uint64_t requestState);
NSString *axs_headsetbridge_cloud_logPath(void);

#ifdef __cplusplus
}
#endif

#define AxsHeadsetBridgeCloudRequest "com.axs.headsetbridge.cloud.request"
#define AxsHeadsetBridgeCloudAck "com.axs.headsetbridge.cloud.ack"

#define AxsHeadsetBridgeCloudLease "com.axs.headsetbridge.cloud.playback-lease-v3"
// uint64 lease = sessionNonce:32 | expiration(systemUptime seconds):32.
// It prevents stale requests, NOT an authentication boundary on a jailbroken phone.

#define AxsHeadsetBridgeCloudConsumed "com.axs.headsetbridge.cloud.consumed-session"
