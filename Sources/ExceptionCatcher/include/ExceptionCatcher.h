#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, converting any Objective-C NSException it raises into an
/// NSError so Swift callers can handle AVFoundation's exception-throwing
/// paths (AVAudioEngine device-change failures) instead of crashing.
NSError *_Nullable LFCatchException(void (^block)(void));

NS_ASSUME_NONNULL_END
