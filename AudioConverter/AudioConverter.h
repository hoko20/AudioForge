#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^AudioProgressBlock)(double progress);

typedef NS_ENUM(NSInteger, AudioOutputFormat) {
    AudioOutputFormatNB = 0,   ///< AMR-NB 12.2 kbps / 8 kHz，.amr，兼容性最好（Swift: .nb）
    AudioOutputFormatWB = 1,   ///< AMR-WB 23.85 kbps / 16 kHz，.amr，明显更清晰（Swift: .wb）
    AudioOutputFormatSilk = 2, ///< SILK v3 25 kbps / 24 kHz，.aud，微信 / QQ 语音（Swift: .silk）
};

typedef NS_ENUM(NSInteger, AudioConverterError) {
    AudioConverterErrorNoAudioTrack = 1,
    AudioConverterErrorReader       = 2,
    AudioConverterErrorEncoder      = 3,
    AudioConverterErrorFile         = 4,
};

FOUNDATION_EXPORT NSString *const AudioConverterErrorDomain;

/// 把任意带音轨的媒体（MP3 / MP4 / M4A / MOV / WAV / AAC 等）转成
/// AMR-NB / AMR-WB（.amr）或 SILK v3（.aud，微信 / QQ 语音格式）。
@interface AudioConverter : NSObject

/// 输出文件扩展名：amr / aud
+ (NSString *)fileExtensionForFormat:(AudioOutputFormat)format
    NS_SWIFT_NAME(fileExtension(for:));

/// 注意：NSError** 参数按 Swift 约定导入为 throws，
/// Swift 侧签名是 convertMedia(at:to:format:progress:)。
+ (BOOL)convertMediaAtURL:(NSURL *)inputURL
                    toURL:(NSURL *)outputURL
                   format:(AudioOutputFormat)format
                 progress:(nullable AudioProgressBlock)progress
                    error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(convertMedia(at:to:format:progress:));

@end

NS_ASSUME_NONNULL_END
