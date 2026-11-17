#pragma once
#import <Foundation/Foundation.h>
#ifdef __cplusplus
extern "C" {
#endif
void axs_headsetcardtimer_start(void);
void axs_headsetcardtimer_configChanged(void);
void axs_headsetcardtimer_log(NSString *event, NSDictionary *fields);
#ifdef __cplusplus
}
#endif
