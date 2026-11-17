#import "AxsHeadsetCardTimerRuntime.h"
#import <os/log.h>
#import <unistd.h>

void axs_headsetcardtimer_log(NSString *event,NSDictionary *fields) {
    @try {
        static dispatch_queue_t queue;static os_log_t unified;static dispatch_once_t once;
        dispatch_once(&once,^{queue=dispatch_queue_create("com.axs.headsetcardtimer.log",DISPATCH_QUEUE_SERIAL);unified=os_log_create("com.axs.headsetcardtimer","card");});
        NSMutableDictionary *row=[NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
        row[@"event"]=event;row[@"revision"]=@2;row[@"integration_revision"]=@1;row[@"experiment"]=@"bounded-existing-card-discovery";row[@"pid"]=@(getpid());row[@"time"]=@([NSDate date].timeIntervalSince1970);row[@"uptime"]=@([NSProcessInfo processInfo].systemUptime);
        NSData *data=[NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil];if (!data)return;
        os_log_with_type(unified,OS_LOG_TYPE_DEFAULT,"HSCARD %{public}@",[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
        dispatch_async(queue,^{
            @try {
                NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/HeadsetCardTimer-events.jsonl"];
                NSFileManager *fm=[NSFileManager defaultManager];[fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
                if ([[fm attributesOfItemAtPath:path error:nil] fileSize]+data.length+1>512*1024) {
                    NSString *old=[path stringByAppendingString:@".previous"];
                    [fm removeItemAtPath:old error:nil];if (![fm moveItemAtPath:path toPath:old error:nil])return;
                }
                if (![fm fileExistsAtPath:path])[fm createFileAtPath:path contents:nil attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication}];
                NSFileHandle *handle=[NSFileHandle fileHandleForWritingAtPath:path];if (!handle)return;
                @try { [handle seekToEndOfFile];[handle writeData:data];[handle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]]; }
                @finally { [handle closeFile]; }
            } @catch(NSException *e) { (void)e; }
        });
    } @catch(NSException *e) { (void)e; }
}
