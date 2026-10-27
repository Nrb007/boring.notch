//
//  ClipboardLaunchHook.m
//  boringNotch
//
//  Starts the clipboard history once the app has finished launching, so it records from launch
//  and not only once its page has been opened, without touching the app delegate. The history
//  itself only records while the Clipboard utility is turned on (see ClipboardHistoryService).
//
//  Swift has no load-time hook, hence this one Objective-C file. If the app delegate ever calls
//  `ClipboardHistoryService.shared.activate()` from applicationDidFinishLaunching, this file can go.
//

#import <AppKit/AppKit.h>

@protocol BNClipboardHistoryLaunching
+ (void)start;
@end

@interface BNClipboardLaunchHook : NSObject
@end

@implementation BNClipboardLaunchHook

+ (void)load {
    __block id token = nil;
    token = [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
        [[NSNotificationCenter defaultCenter] removeObserver:token];
        token = nil;
        Class launcher = NSClassFromString(@"BNClipboardHistoryLaunch");
        if ([launcher respondsToSelector:@selector(start)]) {
            [(Class<BNClipboardHistoryLaunching>)launcher start];
        }
    }];
}

@end
