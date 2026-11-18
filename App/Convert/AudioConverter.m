#import "AudioConverter.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <math.h>
#import <string.h>

// 编码器头文件由 Scripts/build-audio-codecs.sh 产出到 Vendor/include
#import "interf_enc.h"        // AMR-NB（opencore-amr）
#import "enc_if.h"            // AMR-WB（vo-amrwbenc）
#import "SKP_Silk_SDK_API.h"  // SILK v3（腾讯语音）

NSString *const AudioConverterErrorDomain = @"local.xchat.audioforge";

#pragma mark - 编码器上下文

typedef struct {
    AudioOutputFormat format;
    NSUInteger frameSamples;      // 20ms 采样数
    void *nbState;
    void *wbState;
    void *silkState;
    SKP_SILK_SDK_EncControlStruct silkControl;
    NSUInteger encodedFrames;
} AudioConverterContext;

static int AudioSampleRate(AudioOutputFormat format) {
    switch (format) {
        case AudioOutputFormatNB: return 8000;
        case AudioOutputFormatWB: return 16000;
        case AudioOutputFormatSilk:  return 24000;
        case AudioOutputFormatM4A:   return 44100;
    }
    return 8000;
}

static void AudioWriteHeader(NSFileHandle *handle, AudioOutputFormat format) {
    static const unsigned char nbHeader[] = {0x23, 0x21, 0x41, 0x4D, 0x52, 0x0A};              // #!AMR\n
    static const unsigned char wbHeader[] = {0x23, 0x21, 0x41, 0x4D, 0x52, 0x2D, 0x57, 0x42, 0x0A}; // #!AMR-WB\n
    static const unsigned char silkHeader[] = {0x02, 0x23, 0x21, 0x53, 0x49, 0x4C, 0x4B,
                                               0x5F, 0x56, 0x33};                                  // \x02#!SILK_V3

    switch (format) {
        case AudioOutputFormatNB:
            [handle writeData:[NSData dataWithBytes:nbHeader length:sizeof(nbHeader)]];
            break;
        case AudioOutputFormatWB:
            [handle writeData:[NSData dataWithBytes:wbHeader length:sizeof(wbHeader)]];
            break;
        case AudioOutputFormatSilk:
            [handle writeData:[NSData dataWithBytes:silkHeader length:sizeof(silkHeader)]];
            break;
        case AudioOutputFormatM4A:
            break;
    }
}

/// SILK 规范码率范围是 6–40 kbps；超过 30 kbps 才会进入 24 kHz（SWB）内部带宽。
/// 依次尝试，编码器不接受就降档；全部失败才报错。
static BOOL AudioInitSilkEncoder(AudioConverterContext *ctx, NSString **message) {
    static const struct {
        SKP_int bitRate;
        SKP_int complexity;
    } presets[] = {
        {40000, 10},
        {36000, 10},
        {32000, 8},
        {25000, 2},
    };

    SKP_int size = 0;
    if (SKP_Silk_SDK_Get_Encoder_Size(&size) != 0 || size <= 0) {
        *message = @"SILK 编码器初始化失败";
        return NO;
    }

    ctx->silkState = malloc((size_t)size);
    if (!ctx->silkState) {
        *message = @"SILK 编码器初始化失败";
        return NO;
    }

    SKP_int16 silence[480];
    memset(silence, 0, sizeof(silence));
    unsigned char payload[1024];

    for (size_t i = 0; i < sizeof(presets) / sizeof(presets[0]); i++) {
        SKP_SILK_SDK_EncControlStruct initial;
        memset(&initial, 0, sizeof(initial));
        if (SKP_Silk_SDK_InitEncoder(ctx->silkState, &initial) != 0) {
            continue;
        }

        memset(&ctx->silkControl, 0, sizeof(ctx->silkControl));
        ctx->silkControl.API_sampleRate = 24000;
        ctx->silkControl.maxInternalSampleRate = 24000;
        ctx->silkControl.packetSize = 480;              // 20ms @24kHz
        ctx->silkControl.bitRate = presets[i].bitRate;
        ctx->silkControl.packetLossPercentage = 0;
        ctx->silkControl.complexity = presets[i].complexity;
        ctx->silkControl.useInBandFEC = 0;
        ctx->silkControl.useDTX = 0;

        // 用一帧静音试编，确认这套参数被当前 SDK 接受
        SKP_int16 bytes = (SKP_int16)sizeof(payload);
        if (SKP_Silk_SDK_Encode(ctx->silkState, &ctx->silkControl, silence,
                                (SKP_int16)ctx->frameSamples, payload, &bytes) == 0 && bytes > 0) {
            // 试编消耗了一帧，重新初始化让正式编码从干净状态开始
            SKP_SILK_SDK_EncControlStruct fresh;
            memset(&fresh, 0, sizeof(fresh));
            SKP_Silk_SDK_InitEncoder(ctx->silkState, &fresh);
            return YES;
        }
    }

    free(ctx->silkState);
    ctx->silkState = NULL;
    *message = @"SILK 编码器初始化失败";
    return NO;
}

static BOOL AudioInitEncoder(AudioConverterContext *ctx, NSString **message) {
    switch (ctx->format) {
        case AudioOutputFormatNB:
            ctx->nbState = Encoder_Interface_init(0);
            if (!ctx->nbState) {
                *message = @"AMR-NB 编码器初始化失败";
                return NO;
            }
            return YES;

        case AudioOutputFormatWB:
            ctx->wbState = E_IF_init();
            if (!ctx->wbState) {
                *message = @"AMR-WB 编码器初始化失败";
                return NO;
            }
            return YES;

        case AudioOutputFormatSilk: {
            if (!AudioInitSilkEncoder(ctx, message)) {
                return NO;
            }
            return YES;
        }
    }
    return NO;
}

static void AudioReleaseEncoder(AudioConverterContext *ctx) {
    if (ctx->nbState) {
        Encoder_Interface_exit(ctx->nbState);
        ctx->nbState = NULL;
    }
    if (ctx->wbState) {
        E_IF_exit(ctx->wbState);
        ctx->wbState = NULL;
    }
    if (ctx->silkState) {
        free(ctx->silkState);
        ctx->silkState = NULL;
    }
}

/// 编码一帧并写入文件；返回 NO 表示编码器报错。
static BOOL AudioEncodeFrame(AudioConverterContext *ctx, NSFileHandle *handle,
                             const short *pcm) {
    unsigned char payload[1024];
    int size = -1;

    switch (ctx->format) {
        case AudioOutputFormatNB:
            size = Encoder_Interface_Encode(ctx->nbState, MR122, pcm, payload, 0);
            break;
        case AudioOutputFormatWB:
            // mode 8 = 23.85 kbps，AMR-WB 最高档
            size = E_IF_encode(ctx->wbState, 8, pcm, payload, 0);
            break;
        case AudioOutputFormatSilk: {
            SKP_int16 bytes = (SKP_int16)sizeof(payload);
            if (SKP_Silk_SDK_Encode(ctx->silkState, &ctx->silkControl, pcm,
                                    (SKP_int16)ctx->frameSamples, payload, &bytes) == 0) {
                size = bytes;
            }
            break;
        }
    }

    if (size <= 0) return NO;

    if (ctx->format == AudioOutputFormatSilk) {
        // 微信 / QQ 的每帧格式：2 字节小端长度 + 帧数据
        int16_t little = (int16_t)size;
        [handle writeData:[NSData dataWithBytes:&little length:sizeof(little)]];
    }
    [handle writeData:[NSData dataWithBytes:payload length:(NSUInteger)size]];
    ctx->encodedFrames++;
    return YES;
}

#pragma mark - AudioConverter

@interface AudioConverter ()
+ (BOOL)convertM4AAtURL:(NSURL *)inputURL
                  toURL:(NSURL *)outputURL
               progress:(nullable AudioProgressBlock)progress
                  error:(NSError *_Nullable *_Nullable)error;
@end

@implementation AudioConverter

+ (NSString *)fileExtensionForFormat:(AudioOutputFormat)format {
    switch (format) {
        case AudioOutputFormatSilk: return @"aud";
        case AudioOutputFormatM4A:  return @"m4a";
        default:                    return @"amr";
    }
}

+ (BOOL)convertMediaAtURL:(NSURL *)inputURL
                    toURL:(NSURL *)outputURL
                   format:(AudioOutputFormat)format
                 progress:(AudioProgressBlock)progress
                    error:(NSError **)error {
    if (format == AudioOutputFormatM4A) {
        return [self convertM4AAtURL:inputURL toURL:outputURL progress:progress error:error];
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:inputURL options:nil];

    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!track) {
        [self fill:error code:AudioConverterErrorNoAudioTrack message:@"这个文件里没有可用的音轨"];
        return NO;
    }

    NSError *readerError = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
    if (!reader) {
        [self fill:error code:AudioConverterErrorReader
           message:readerError.localizedDescription ?: @"无法读取该文件"];
        return NO;
    }

    // 让系统按目标格式重采样：NB 8k / WB 16k / SILK 24k，统一单声道 16bit
    const int sampleRate = AudioSampleRate(format);
    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(sampleRate),
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
        [self fill:error code:AudioConverterErrorReader message:@"不支持这个文件的音频格式"];
        return NO;
    }
    [reader addOutput:output];

    if (![reader startReading]) {
        [self fill:error code:AudioConverterErrorReader
           message:reader.error.localizedDescription ?: @"读取失败"];
        return NO;
    }

    NSFileManager *manager = [NSFileManager defaultManager];
    [manager removeItemAtURL:outputURL error:nil];
    if (![manager createFileAtPath:outputURL.path contents:nil attributes:nil]) {
        [self fill:error code:AudioConverterErrorFile message:@"无法创建输出文件"];
        return NO;
    }

    NSError *handleError = nil;
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:outputURL error:&handleError];
    if (!handle) {
        [self fill:error code:AudioConverterErrorFile
           message:handleError.localizedDescription ?: @"输出文件不可写"];
        return NO;
    }

    AudioWriteHeader(handle, format);

    AudioConverterContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.format = format;
    ctx.frameSamples = (NSUInteger)(sampleRate / 50); // 20ms

    NSString *initMessage = nil;
    if (!AudioInitEncoder(&ctx, &initMessage)) {
        [handle closeFile];
        [manager removeItemAtURL:outputURL error:nil];
        [self fill:error code:AudioConverterErrorEncoder message:initMessage ?: @"编码器初始化失败"];
        return NO;
    }

    short pcm[960]; // 48kHz 时的 20ms 上限，实际按 frameSamples 使用
    NSUInteger filled = 0;
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
                        if (filled == ctx.frameSamples) {
                            if (!AudioEncodeFrame(&ctx, handle, pcm)) {
                                encoderFailed = YES;
                            }
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

    AudioReleaseEncoder(&ctx);
    [handle closeFile];

    if (encoderFailed) {
        [manager removeItemAtURL:outputURL error:nil];
        [self fill:error code:AudioConverterErrorEncoder message:@"编码过程中出错，可能是源音频格式异常"];
        return NO;
    }

    if (reader.status == AVAssetReaderStatusFailed) {
        [manager removeItemAtURL:outputURL error:nil];
        [self fill:error code:AudioConverterErrorReader
           message:reader.error.localizedDescription ?: @"转换过程中读取失败"];
        return NO;
    }

    if (ctx.encodedFrames == 0) {
        [manager removeItemAtURL:outputURL error:nil];
        [self fill:error code:AudioConverterErrorReader
           message:@"没有解出任何音频数据，可能是纯视频（无音轨）或格式不被支持"];
        return NO;
    }

    if (progress) progress(1.0);
    return YES;
}

/// AAC（.m4a）高保真导出：解码成 44.1kHz / 16bit PCM 后用系统 AAC 编码器
/// 以 256 kbps 立体声重新封装，音质接近原文件。
+ (BOOL)convertM4AAtURL:(NSURL *)inputURL
                  toURL:(NSURL *)outputURL
               progress:(AudioProgressBlock)progress
                  error:(NSError **)error {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:inputURL options:nil];
    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!track) {
        [self fill:error code:AudioConverterErrorNoAudioTrack message:@"这个文件里没有可用的音轨"];
        return NO;
    }

    NSError *readerError = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
    if (!reader) {
        [self fill:error code:AudioConverterErrorReader
           message:readerError.localizedDescription ?: @"无法读取该文件"];
        return NO;
    }

    const int sampleRate = 44100;
    NSDictionary *readSettings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(sampleRate),
        AVNumberOfChannelsKey: @2,
        AVLinearPCMBitDepthKey: @16,
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsNonInterleaved: @NO,
    };

    AVAssetReaderTrackOutput *output =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:readSettings];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) {
        // 个别纯单声道 / 多声道素材不允许直接升混，退回单声道
        readSettings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @(sampleRate),
            AVNumberOfChannelsKey: @1,
            AVLinearPCMBitDepthKey: @16,
            AVLinearPCMIsFloatKey: @NO,
            AVLinearPCMIsBigEndianKey: @NO,
            AVLinearPCMIsNonInterleaved: @NO,
        };
        output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:readSettings];
        output.alwaysCopiesSampleData = NO;
        if (![reader canAddOutput:output]) {
            [self fill:error code:AudioConverterErrorReader message:@"不支持这个文件的音频格式"];
            return NO;
        }
    }
    [reader addOutput:output];

    NSFileManager *manager = [NSFileManager defaultManager];
    [manager removeItemAtURL:outputURL error:nil];

    NSError *writerError = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:outputURL
                                                      fileType:AVFileTypeAppleM4A
                                                         error:&writerError];
    if (!writer) {
        [self fill:error code:AudioConverterErrorFile
           message:writerError.localizedDescription ?: @"无法创建输出文件"];
        return NO;
    }

    const int channels = [readSettings[AVNumberOfChannelsKey] intValue];
    NSDictionary *writeSettings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @(sampleRate),
        AVNumberOfChannelsKey: @(channels),
        AVEncoderBitRateKey: @(channels > 1 ? 256000 : 128000),
        AVEncoderAudioQualityKey: @(AVAudioQualityMax),
    };
    AVAssetWriterInput *input =
        [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:writeSettings];
    input.expectsMediaDataInRealTime = NO;
    if (![writer canAddInput:input]) {
        [self fill:error code:AudioConverterErrorEncoder message:@"系统 AAC 编码器不可用"];
        return NO;
    }
    [writer addInput:input];

    if (![reader startReading] || ![writer startWriting]) {
        [self fill:error code:AudioConverterErrorReader
           message:reader.error.localizedDescription ?: writer.error.localizedDescription ?: @"转换启动失败"];
        return NO;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    const double duration = CMTimeGetSeconds(asset.duration);
    while (reader.status == AVAssetReaderStatusReading) {
        @autoreleasepool {
            CMSampleBufferRef sample = [output copyNextSampleBuffer];
            if (!sample) break;

            while (!input.isReadyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) {
                [NSThread sleepForTimeInterval:0.002];
            }
            if (writer.status != AVAssetWriterStatusWriting || ![input appendSampleBuffer:sample]) {
                CFRelease(sample);
                break;
            }

            if (progress && duration > 0) {
                const double stamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
                if (isfinite(stamp) && stamp >= 0) {
                    progress(MIN(1.0, stamp / duration));
                }
            }
            CFRelease(sample);
        }
    }

    [input markAsFinished];
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    BOOL failed = writer.status != AVAssetWriterStatusCompleted
        || reader.status == AVAssetReaderStatusFailed;
    if (failed) {
        [manager removeItemAtURL:outputURL error:nil];
        [self fill:error code:AudioConverterErrorEncoder
           message:writer.error.localizedDescription ?: reader.error.localizedDescription ?: @"导出 m4a 失败"];
        return NO;
    }

    if (progress) progress(1.0);
    return YES;
}

+ (void)fill:(NSError **)error code:(AudioConverterError)code message:(NSString *)message {
    if (!error) return;
    *error = [NSError errorWithDomain:AudioConverterErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey: message ?: @"转换失败"}];
}

@end
