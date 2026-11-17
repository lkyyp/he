#pragma once
#import <Foundation/Foundation.h>
#ifdef __cplusplus
extern "C" {
#endif
void axs_headsetbridge_card_configStart(void);
BOOL axs_headsetbridge_card_enabled(void);
NSTimeInterval axs_headsetbridge_card_delay(void);
#ifdef __cplusplus
}
#endif
#define AxsHeadsetBridgeCardLocalChanged @"com.axs.headsetbridge.card.local-changed"
