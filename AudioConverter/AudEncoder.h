#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^AUDProgressBlock)(double progress);

typedef NS_ENUM(NSInteger, AUDEncoderError) {
    AUDEncoderErrorNoAudioTrack = 1,
    AUDEncoderErrorReader       = 2,
    AUDEncoderErrorEncoder      = 3,
    AUDEncoderErrorFile         = 4,
};

FOUNDATION_EXPORT NSString *const AUDEncoderErrorDomain;

/// 把任意带音轨的媒体（MP3 / MP4 / M4A / MOV / WAV / AAC 等）转成 .aud
/// —— SILK v3（24 kHz 单声道 25 kbps，微信 / QQ 语音格式）。
@interface AudEncoder : NSObject

/// 注意：NSError** 参数按 Swift 约定导入为 throws，
/// Swift 侧签名是 convertMedia(at:to:progress:)（不要把 error: 写进 Swift 名）。
+ (BOOL)convertMediaAtURL:(NSURL *)inputURL
                    toURL:(NSURL *)outputURL
                 progress:(nullable AUDProgressBlock)progress
                    error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(convertMedia(at:to:progress:));

@end

NS_ASSUME_NONNULL_END
