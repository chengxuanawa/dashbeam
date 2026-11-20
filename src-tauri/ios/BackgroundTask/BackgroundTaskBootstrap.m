#import <Foundation/Foundation.h>

extern void dashbeam_bg_register(void);

static id DashBeamBackgroundTaskObserver __attribute__((used)) = nil;

__attribute__((constructor)) static void DashBeamBackgroundTaskBootstrap(void) {
    DashBeamBackgroundTaskObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:@"UIApplicationDidFinishLaunchingNotification"
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    (void)note;
                    dashbeam_bg_register();
                }];
}
