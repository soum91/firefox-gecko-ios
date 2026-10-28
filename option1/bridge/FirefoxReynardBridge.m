// First-stage original-Firefox injection probe, NOT a Gecko renderer.
// This library is injected into the decrypted Firefox Client executable
// without replacing the original native user interface or icons.
// Its sole job now is to establish that the independently re-signed app can
// load our bridge. Replacing WebKit rendering requires a separate implementation.
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

__attribute__((visibility("default")))
const char *FirefoxReynardBridgeVersion(void) {
    return "0.1.0-preengine";
}

__attribute__((constructor))
static void FirefoxReynardBridgeInitialize(void) {
    // Avoid touching UIKit or Firefox state during dyld initialization.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"FirefoxReynardBridge loaded; Gecko substitution is NOT enabled.");
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"FirefoxReynardBridgeLoaded"
                          object:nil];
    });
}
