#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 把本 App 生成的 AMR（NB / WB）与 SILK v3（.aud）解码成 16bit 单声道 WAV，
/// 供 AVAudioPlayer 直接播放。其它格式（mp3 / m4a / wav 等）无需经过这里。
@interface AudioPlayback : NSObject

/// .aud / .amr 需要先解码。
+ (BOOL)isDecodablePath:(NSString *)path
    NS_SWIFT_NAME(isDecodablePath(_:));

/// 解码为 WAV。失败时 error 里是可直接展示的中文原因。
/// Swift 侧签名为 decodeAudio(at:toWAVURL:) throws。
+ (BOOL)decodeAudioAtURL:(NSURL *)inputURL
                toWAVURL:(NSURL *)outputURL
                   error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(decodeAudio(at:toWAVURL:));

@end

NS_ASSUME_NONNULL_END
