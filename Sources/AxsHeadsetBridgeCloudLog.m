#import "AxsHeadsetBridgeCloudRuntime.h"
NSString *axs_headsetbridge_cloud_logPath(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqual:@"com.apple.springboard"] ? @"/var/mobile/Library/Logs/HeadsetBridge-springboard.jsonl" : [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/HeadsetBridge-music.jsonl"];
}
void axs_headsetbridge_cloud_log(NSString *event, NSDictionary *fields) { axs_headsetbridge_engineLog(@"cloud",event,fields); }
