#import "AudEncoder.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <string.h>

// SILK v3 头文件与静态库由 Scripts/build-silk.sh 产出到 Vendor
#import "SKP_Silk_SDK_API.h"

NSString *const AUDEncoderErrorDomain = @"local.xchat.audioforge";

/// 输出参数（微信 / QQ 的 .aud 语音格式）
static const int AUDSampleRate      = 24000;
static const NSUInteger AUDFrameMs  = 20;      // 每帧 20ms
static const SKP_int32 AUDBitRate   = 25000;   // 25 kbps，SILK 高音质档

/// 编码一帧并写入（2 字节小端长度 + 帧数据）；返回 NO 表示编码器报错。
static BOOL AUDFrameEncode(NSFileHandle *handle, void *silkState,
                           SKP_SILK_SDK_EncControlStruct *control,
                           const short *pcm, SKP_int frameSamples,
                           NSUInteger *encodedFrames) {
    unsigned char payload[1024];
    SKP_int16 size = (SKP_int16)sizeof(payload);
    if (SKP_Silk_SDK_Encode(silkState, control, pcm, frameSamples, payload, &size) != 0) {
        return NO;
    }
    if (size <= 0) return NO;

    [handle writeData:[NSData dataWithBytes:&size length:sizeof(size)]];
    [handle writeData:[NSData dataWithBytes:payload length:(NSUInteger)size]];
    (*encodedFrames)++;
    return YES;
}

@implementation AudEncoder

+ (BOOL)convertMediaAtURL:(NSURL *)inputURL
                    toURL:(NSURL *)outputURL
                 progress:(AUDProgressBlock)progress
                    error:(NSError **)error {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:inputURL options:nil];

    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!track) {
        [self fill:error code:AUDEncoderErrorNoAudioTrack message:@"这个文件里没有可用的音轨"];
        return NO;
    }

    NSError *readerError = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
    if (!reader) {
        [self fill:error code:AUDEncoderErrorReader
           message:readerError.localizedDescription ?: @"无法读取该文件"];
        return NO;
    }

    // 让系统重采样到 24 kHz 单声道 16bit，SILK 编码器直接吃这份 PCM
    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(AUDSampleRate),
        AVNumberOfChannelsKey: @1,
        AVLinearPCMBitDepthKey: @16,
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsNonInterleaved: @NO,
    };

    AVAssetReaderTrackOutput *output =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) {
        [self fill:error code:AUDEncoderErrorReader message:@"不支持这个文件的音频格式"];
        return NO;
    }
    [reader addOutput:output];

    if (![reader startReading]) {
        [self fill:error code:AUDEncoderErrorReader
           message:reader.error.localizedDescription ?: @"读取失败"];
        return NO;
    }

    NSFileManager *manager = [NSFileManager defaultManager];
    [manager removeItemAtURL:outputURL error:nil];
    if (![manager createFileAtPath:outputURL.path contents:nil attributes:nil]) {
        [self fill:error code:AUDEncoderErrorFile message:@"无法创建输出文件"];
        return NO;
    }

    NSError *handleError = nil;
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:outputURL error:&handleError];
    if (!handle) {
        [self fill:error code:AUDEncoderErrorFile
           message:handleError.localizedDescription ?: @"输出文件不可写"];
        return NO;
    }

    // 微信 / QQ 的文件头：\x02#!SILK_V3
    static const unsigned char silkHeader[] = {0x02, 0x23, 0x21, 0x53, 0x49, 0x4C, 0x4B,
                                               0x5F, 0x56, 0x33};
    [handle writeData:[NSData dataWithBytes:silkHeader length:sizeof(silkHeader)]];

    SKP_int encoderSize = 0;
    if (SKP_Silk_SDK_Get_Encoder_Size(&encoderSize) != 0 || encoderSize <= 0) {
        [handle closeFile];
        [manager removeItemAtURL:outputURL error:nil];
        [self fill:error code:AUDEncoderErrorEncoder message:@"SILK 编码器初始化失败"];
        return NO;
    }
    void *silkState = malloc((size_t)encoderSize);
    SKP_SILK_SDK_EncControlStruct status;
    memset(&status, 0, sizeof(status));
    if (!silkState || SKP_Silk_SDK_InitEncoder(silkState, &status) != 0) {
        free(silkState);
        [handle closeFile];
        [manager removeItemAtURL:outputURL error:nil];
        [self fill:error code:AUDEncoderErrorEncoder message:@"SILK 编码器初始化失败"];
        return NO;
    }

    SKP_SILK_SDK_EncControlStruct control;
    memset(&control, 0, sizeof(control));
    control.API_sampleRate           = AUDSampleRate;
    control.maxInternalSampleRate    = AUDSampleRate;
    control.packetSize               = (SKP_int)(AUDSampleRate * AUDFrameMs / 1000); // 480
    control.bitRate                  = AUDBitRate;
    control.packetLossPercentage     = 0;
    control.complexity               = 8;   // 高复杂度 = 更好音质
    control.useInBandFEC             = 0;
    control.useDTX                   = 0;

    const NSUInteger frameSamples = (NSUInteger)(AUDSampleRate * AUDFrameMs / 1000);
    short pcm[480];
    NSUInteger filled = 0;
    NSUInteger encodedFrames = 0;
    const double duration = CMTimeGetSeconds(asset.duration);
    BOOL encoderFailed = NO;

    while (reader.status == AVAssetReaderStatusReading) {
        @autoreleasepool {
            CMSampleBufferRef sample = [output copyNextSampleBuffer];
            if (!sample) break;

            CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
            if (block) {
                char *pointer = NULL;
                size_t total = 0;
                if (CMBlockBufferGetDataPointer(block, 0, NULL, &total, &pointer) == kCMBlockBufferNoErr
                    && pointer != NULL) {
                    const short *samples = (const short *)pointer;
                    const size_t count = total / sizeof(short);
                    for (size_t i = 0; i < count && !encoderFailed; i++) {
                        pcm[filled++] = samples[i];
                        if (filled == frameSamples) {
                            encoderFailed = !AUDFrameEncode(handle, silkState, &control,
                                                            pcm, (SKP_int)frameSamples,
                                                            &encodedFrames);
                            filled = 0;
                        }
                    }
                }
            }

            if (progress && duration > 0) {
                const double stamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
                if (isfinite(stamp) && stamp >= 0) {
                    progress(MIN(1.0, stamp / duration));
                }
            }

            CFRelease(sample);
        }
        if (encoderFailed) break;
    }

    free(silkState);
    [handle closeFile];

    if (encoderFailed) {
        [manager removeItemAtURL:outputURL error:nil];
        [self fill:error code:AUDEncoderErrorEncoder message:@"编码过程中出错，可能是源音频格式异常"];
        return NO;
    }

    if (reader.status == AVAssetReaderStatusFailed) {
        [manager removeItemAtURL:outputURL error:nil];
        [self fill:error code:AUDEncoderErrorReader
           message:reader.error.localizedDescription ?: @"转换过程中读取失败"];
        return NO;
    }

    if (encodedFrames == 0) {
        [manager removeItemAtURL:outputURL error:nil];
        [self fill:error code:AUDEncoderErrorReader
           message:@"没有解出任何音频数据，可能是纯视频（无音轨）或格式不被支持"];
        return NO;
    }

    if (progress) progress(1.0);
    return YES;
}

+ (void)fill:(NSError **)error code:(AUDEncoderError)code message:(NSString *)message {
    if (!error) return;
    *error = [NSError errorWithDomain:AUDEncoderErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey: message ?: @"转换失败"}];
}

@end
