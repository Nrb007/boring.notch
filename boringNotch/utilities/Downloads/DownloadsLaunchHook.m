//
//  DownloadsLaunchHook.m
//  boringNotch
//
//  The Downloads utility follows downloads while the notch is closed, so its monitor has to start
//  at launch rather than when its page first opens. Swift can't run code at load time, so this
//  +load hands off to the Swift side (DownloadsLaunchHook in DownloadsService.swift) on the main
//  queue, which drains once the app's run loop is up. It only registers a Defaults observer; the
//  monitor itself runs while the utility is switched on.
//

#import <Foundation/Foundation.h>

@protocol BNDownloadsLaunching <NSObject>
+ (void)startAtLaunch;
@end

@interface BNDownloadsLaunchTrigger : NSObject
@end

@implementation BNDownloadsLaunchTrigger

+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class hook = NSClassFromString(@"BNDownloadsLaunchHook");
        if ([hook respondsToSelector:@selector(startAtLaunch)]) {
            [(Class<BNDownloadsLaunching>)hook startAtLaunch];
        }
    });
}

@end
