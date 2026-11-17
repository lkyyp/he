#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Diagnostic-only token. No Objective-C references or playback authorization.
typedef struct {
    unsigned depth, window;
    uint64_t generation, call;
    double started;
    BOOL restore;
} AxsHeadsetBridgeAudioScope;
void axs_headsetbridge_audioStatusStart(void);
AxsHeadsetBridgeAudioScope axs_headsetbridge_audioScopeEnter(BOOL candidate, unsigned window, uint64_t call);
void axs_headsetbridge_audioScopeLeave(AxsHeadsetBridgeAudioScope saved);
#ifdef __cplusplus
}
#endif
