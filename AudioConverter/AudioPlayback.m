#import "AudioPlayback.h"
#import "interf_dec.h"
#import "dec_if.h"
#import "SKP_Silk_SDK_API.h"
#include <string.h>

NSString *const AudioPlaybackErrorDomain = @"local.xchat.audioforge.playback";

typedef NS_ENUM(NSInteger, AudioPlaybackError) {
    AudioPlaybackErrorUnsupported = 1,
    AudioPlaybackErrorFormat      = 2,
    AudioPlaybackErrorDecoder     = 3,
    AudioPlaybackErrorFile        = 4,
};

// AMR-NB：每帧首字节 ToC 之后的负载长度（按 mode 0…15）
static const unsigned char kAMRNBPayloadSize[16] = {
    12, 13, 15, 17, 19, 20, 26, 31, 5, 0, 0, 0, 0, 0, 0, 0
};
// AMR-WB：含 ToC 字节在内的整帧长度（按 mode 0…15）
static const int kAMRWBFrameSize[16] = {
    18, 24, 33, 37, 41, 47, 51, 59, 61, 65, 67, 71, 71, 71, 71, 0
};

#pragma mark - WAV

static void AudioAppendLE32(NSMutableData *data, uint32_t value) {
    unsigned char raw[4] = {
        (unsigned char)(value & 0xFF), (unsigned char)((value >> 8) & 0xFF),
        (unsigned char)((value >> 16) & 0xFF), (unsigned char)((value >> 24) & 0xFF),
    };
    [data appendBytes:raw length:sizeof(raw)];
}

static void AudioAppendLE16(NSMutableData *data, uint16_t value) {
    unsigned char raw[2] = { (unsigned char)(value & 0xFF), (unsigned char)((value >> 8) & 0xFF) };
    [data appendBytes:raw length:sizeof(raw)];
}

/// 44 字节 PCM16 单声道 WAV 头，数据长度部分先写 0，解码完回填。
static NSMutableData *AudioWAVHeader(uint32_t sampleRate) {
    NSMutableData *header = [NSMutableData data];
    [header appendBytes:"RIFF" length:4];
    AudioAppendLE32(header, 0);
    [header appendBytes:"WAVEfmt " length:8];
    AudioAppendLE32(header, 16);
    AudioAppendLE16(header, 1);                            // PCM
    AudioAppendLE16(header, 1);                            // 单声道
    AudioAppendLE32(header, sampleRate);
    AudioAppendLE32(header, sampleRate * 2);               // byte rate
    AudioAppendLE16(header, 2);                            // block align
    AudioAppendLE16(header, 16);                           // bits
    [header appendBytes:"data" length:4];
    AudioAppendLE32(header, 0);
    return header;
}

static void AudioPatchWAVHeader(NSFileHandle *handle, uint32_t dataBytes) {
    [handle seekToFileOffset:4];
    NSMutableData *chunk = [NSMutableData data];
    AudioAppendLE32(chunk, dataBytes + 36);
    [handle writeData:chunk];
    [handle seekToFileOffset:40];
    chunk = [NSMutableData data];
    AudioAppendLE32(chunk, dataBytes);
    [handle writeData:chunk];
}

#pragma mark - SILK v3

static BOOL AudioDecodeSilk(NSData *data, NSFileHandle *handle, NSString **message) {
    const unsigned char *bytes = data.bytes;
    NSUInteger length = data.length;
    static const unsigned char silkHeader[] = {0x02, 0x23, 0x21, 0x53, 0x49, 0x4C, 0x4B,
                                               0x5F, 0x56, 0x33};
    if (length < sizeof(silkHeader) || memcmp(bytes, silkHeader, sizeof(silkHeader)) != 0) {
        *message = @"不是有效的 SILK v3 文件";
        return NO;
    }

    SKP_int decoderSize = 0;
    if (SKP_Silk_SDK_Get_Decoder_Size(&decoderSize) != 0 || decoderSize <= 0) {
        *message = @"SILK 解码器初始化失败";
        return NO;
    }
    void *decoder = malloc((size_t)decoderSize);
    if (!decoder) {
        *message = @"内存不足，无法解码";
        return NO;
    }

    SKP_SILK_SDK_DecControlStruct control;
    memset(&control, 0, sizeof(control));
    control.API_sampleRate = 24000;

    if (SKP_Silk_SDK_InitDecoder(decoder) != 0) {
        free(decoder);
        *message = @"SILK 解码器初始化失败";
        return NO;
    }

    SKP_int16 samples[960];
    NSUInteger offset = sizeof(silkHeader);
    BOOL ok = YES;

    while (offset + 2 <= length) {
        int16_t frameSize = 0;
        memcpy(&frameSize, bytes + offset, sizeof(frameSize));
        offset += 2;
        if (frameSize <= 0 || offset + (NSUInteger)frameSize > length) break;

        SKP_int16 outCount = 0;
        if (SKP_Silk_SDK_Decode(decoder, &control, 0, bytes + offset,
                                (SKP_int)frameSize, samples, &outCount) != 0) {
            ok = NO;
            *message = @"SILK 解码失败，文件可能已损坏";
            break;
        }
        offset += (NSUInteger)frameSize;
        if (outCount > 0) {
            [handle writeData:[NSData dataWithBytes:samples length:(NSUInteger)outCount * sizeof(SKP_int16)]];
        }
    }

    free(decoder);
    return ok;
}

#pragma mark - AMR

static BOOL AudioDecodeAMRNB(NSData *data, NSFileHandle *handle, NSString **message) {
    const unsigned char *bytes = data.bytes;
    NSUInteger length = data.length;
    static const char headerText[] = "#!AMR\n";
    if (length < 6 || memcmp(bytes, headerText, 6) != 0) {
        *message = @"不是有效的 AMR-NB 文件";
        return NO;
    }

    void *decoder = Decoder_Interface_init();
    if (!decoder) {
        *message = @"AMR-NB 解码器初始化失败";
        return NO;
    }

    short samples[320];
    NSUInteger offset = 6;
    while (offset < length) {
        unsigned char toc = bytes[offset];
        int mode = (toc >> 3) & 0x0F;
        int payload = kAMRNBPayloadSize[mode];
        if (payload <= 0 || offset + 1 + (NSUInteger)payload > length) break;

        Decoder_Interface_Decode(decoder, bytes + offset, samples, 0);
        [handle writeData:[NSData dataWithBytes:samples length:sizeof(samples)]];
        offset += 1 + (NSUInteger)payload;
    }

    Decoder_Interface_exit(decoder);
    return YES;
}

static BOOL AudioDecodeAMRWB(NSData *data, NSFileHandle *handle, NSString **message) {
    const unsigned char *bytes = data.bytes;
    NSUInteger length = data.length;
    static const char headerText[] = "#!AMR-WB\n";
    if (length < 9 || memcmp(bytes, headerText, 9) != 0) {
        *message = @"不是有效的 AMR-WB 文件";
        return NO;
    }

    void *decoder = D_IF_init();
    if (!decoder) {
        *message = @"AMR-WB 解码器初始化失败";
        return NO;
    }

    short samples[640];
    NSUInteger offset = 9;
    while (offset < length) {
        unsigned char toc = bytes[offset];
        int mode = (toc >> 3) & 0x0F;
        int frame = kAMRWBFrameSize[mode];
        if (frame <= 0 || offset + (NSUInteger)frame > length) break;

        D_IF_decode(decoder, bytes + offset, samples, 0);
        [handle writeData:[NSData dataWithBytes:samples length:sizeof(samples)]];
        offset += (NSUInteger)frame;
    }

    D_IF_exit(decoder);
    return YES;
}

#pragma mark - AudioPlayback

@implementation AudioPlayback

+ (BOOL)isDecodablePath:(NSString *)path {
    NSString *ext = path.pathExtension.lowercaseString;
    return [ext isEqualToString:@"aud"] || [ext isEqualToString:@"amr"];
}

+ (BOOL)decodeAudioAtURL:(NSURL *)inputURL
                toWAVURL:(NSURL *)outputURL
                   error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfURL:inputURL options:0 error:nil];
    if (!data.length) {
        [self fill:error code:AudioPlaybackErrorFile message:@"无法读取音频文件"];
        return NO;
    }

    NSString *ext = inputURL.pathExtension.lowercaseString;
    BOOL isSilk = [ext isEqualToString:@"aud"];
    NSString *message = nil;
    uint32_t sampleRate = isSilk ? 24000 : 8000;

    if (!isSilk) {
        NSData *wbHeader = [@"#!AMR-WB\n" dataUsingEncoding:NSASCIIStringEncoding];
        if (data.length >= wbHeader.length && [data rangeOfData:wbHeader options:0 range:NSMakeRange(0, wbHeader.length)].location == 0) {
            sampleRate = 16000;
        }
    }

    NSFileManager *manager = [NSFileManager defaultManager];
    [manager removeItemAtURL:outputURL error:nil];
    if (![manager createFileAtPath:outputURL.path contents:nil attributes:nil]) {
        [self fill:error code:AudioPlaybackErrorFile message:@"无法创建播放缓存文件"];
        return NO;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:outputURL error:nil];
    if (!handle) {
        [manager removeItemAtURL:outputURL error:nil];
        [self fill:error code:AudioPlaybackErrorFile message:@"播放缓存文件不可写"];
        return NO;
    }

    [handle writeData:AudioWAVHeader(sampleRate)];

    BOOL ok = YES;
    if (isSilk) {
        ok = AudioDecodeSilk(data, handle, &message);
    } else {
        // 区分 AMR-NB 与 AMR-WB：文件头不同
        NSData *nbHeader = [@"#!AMR\n" dataUsingEncoding:NSASCIIStringEncoding];
        if (data.length >= nbHeader.length && [data rangeOfData:nbHeader options:0 range:NSMakeRange(0, nbHeader.length)].location == 0) {
            ok = AudioDecodeAMRNB(data, handle, &message);
        } else {
            ok = AudioDecodeAMRWB(data, handle, &message);
        }
    }

    unsigned long long dataBytes = [handle offsetInFile];
    if (ok && dataBytes <= 44) {
        ok = NO;
        message = @"没有解出任何音频数据";
    }
    if (ok) {
        AudioPatchWAVHeader(handle, (uint32_t)(dataBytes - 44));
    }
    [handle closeFile];

    if (!ok) {
        [manager removeItemAtURL:outputURL error:nil];
        [self fill:error code:AudioPlaybackErrorFormat message:message ?: @"解码失败"];
        return NO;
    }
    return YES;
}

+ (void)fill:(NSError **)error code:(AudioPlaybackError)code message:(NSString *)message {
    if (!error) return;
    *error = [NSError errorWithDomain:AudioPlaybackErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey: message ?: @"解码失败"}];
}

@end
