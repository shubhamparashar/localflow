#import "include/ExceptionCatcher.h"

NSError *LFCatchException(void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: @"unknown";
        NSString *message = [NSString stringWithFormat:@"%@: %@", exception.name, reason];
        return [NSError errorWithDomain:@"LocalFlow.ObjCException"
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey: message}];
    }
}
