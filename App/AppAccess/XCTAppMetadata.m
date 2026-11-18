// App icon lookup for iOS 26.x.
//
// Base chain ported from WQ Files 0.9.5 WQUI.m (kolbicz/WQFiles,
// GPL-3.0-or-later). Upstream documents the root problem in its own comment:
// "iOS 26 refuses this app's icon requests" -- UIKit's private
// _applicationIconImageForBundleIdentifier:format:scale: only hands a fixed
// placeholder to third-party processes, and upstream's fallback only reads
// loose PNGs next to Info.plist. Modern apps ship their icon inside
// Assets.car, so both paths fail and the list falls back to a grey tile.
//
// This implementation keeps the upstream order and adds four sources:
//   A. UIKit private API across format 0..8 with constant-placeholder
//      detection (one format may still work on a given 26.x build).
//   B. LaunchServices / IconServices icon data caches.
//   C. CoreUI extraction of the named icon from the app's Assets.car.
//   D. Any icon-ish loose PNG in the .app directory, not just hardcoded names.
//   E. Closest parent bundle id (extensions), then a neutral symbol tile.
// Every private call is guarded by respondsToSelector + @try/@catch, and
// every candidate image is checked for size and colour variance so a grey
// placeholder can never be presented as a real icon.
// See THIRD_PARTY_NOTICES.md.
#import "XCTAppMetadata.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <ctype.h>
#import <math.h>

@interface UIImage (XCTApplicationIconPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)fmt scale:(CGFloat)scale;
@end

static const CGFloat kXCTIconSide = 48.0;
static NSString *const kXCTUnknownBundle = @"local.sandboxaccess.no-such-application";

// MARK: - Safe dynamic invocation of private APIs

typedef struct {
    __unsafe_unretained id object;
    void *pointer;
} XCTInvokeResult;

static BOOL XCTSetArgument(NSInvocation *inv, NSUInteger idx, id value)
{
    const char *t = [inv.methodSignature getArgumentTypeAtIndex:idx];
    if (!t) return NO;
    switch (t[0]) {
        case '@': { id v = (value == NSNull.null) ? nil : value; [inv setArgument:&v atIndex:idx]; return YES; }
        case 'd': { double v = [value doubleValue]; [inv setArgument:&v atIndex:idx]; return YES; }
        case 'f': { float v = [value floatValue]; [inv setArgument:&v atIndex:idx]; return YES; }
        case 'c': { char v = (char)[value intValue]; [inv setArgument:&v atIndex:idx]; return YES; }
        case 'C': { unsigned char v = (unsigned char)[value intValue]; [inv setArgument:&v atIndex:idx]; return YES; }
        case 's': { short v = (short)[value intValue]; [inv setArgument:&v atIndex:idx]; return YES; }
        case 'S': { unsigned short v = (unsigned short)[value intValue]; [inv setArgument:&v atIndex:idx]; return YES; }
        case 'i': { int v = [value intValue]; [inv setArgument:&v atIndex:idx]; return YES; }
        case 'I': { unsigned int v = [value unsignedIntValue]; [inv setArgument:&v atIndex:idx]; return YES; }
        case 'l': { long v = [value longValue]; [inv setArgument:&v atIndex:idx]; return YES; }
        case 'L': { unsigned long v = [value unsignedLongValue]; [inv setArgument:&v atIndex:idx]; return YES; }
        case 'q': { long long v = [value longLongValue]; [inv setArgument:&v atIndex:idx]; return YES; }
        case 'Q': { unsigned long long v = [value unsignedLongLongValue]; [inv setArgument:&v atIndex:idx]; return YES; }
        case 'B': { BOOL v = [value boolValue]; [inv setArgument:&v atIndex:idx]; return YES; }
        case '^': {
            void *v = NULL;
            if (value != NSNull.null && [value isKindOfClass:NSValue.class]) v = [value pointerValue];
            [inv setArgument:&v atIndex:idx];
            return YES;
        }
        default: return NO;
    }
}

static XCTInvokeResult XCTInvoke(id target, NSString *selName, NSArray *args)
{
    XCTInvokeResult result = { .object = nil, .pointer = NULL };
    if (!target || !selName.length) return result;
    SEL sel = NSSelectorFromString(selName);
    if (![target respondsToSelector:sel]) return result;
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments != args.count + 2) return result;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = target;
    inv.selector = sel;
    for (NSUInteger i = 0; i < args.count; i++) {
        if (!XCTSetArgument(inv, i + 2, args[i])) return result;
    }
    @try {
        [inv invoke];
    } @catch (NSException *exception) {
        return result;
    }
    const char *ret = sig.methodReturnType;
    if (ret && ret[0] == '@' && sig.methodReturnLength == sizeof(id)) {
        __unsafe_unretained id object = nil;
        [inv getReturnValue:&object];
        result.object = object;
    } else if (ret && ret[0] == '^' && sig.methodReturnLength == sizeof(void *)) {
        void *pointer = NULL;
        [inv getReturnValue:&pointer];
        result.pointer = pointer;
    }
    return result;
}

static id XCTInvokeObject(id target, NSString *selName, NSArray *args)
{
    return XCTInvoke(target, selName, args).object;
}

// MARK: - Image analysis

// A 16x16 RGBA fingerprint plus a luminance standard deviation. A real icon
// has colour variation; iOS's generic "unknown app" tile is nearly flat.
static NSData *XCTIconPixels(UIImage *image, double *outDeviation)
{
    if (outDeviation) *outDeviation = 0;
    if (!image || !image.CGImage) return nil;
    const size_t side = 16;
    uint8_t px[16 * 16 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return nil;
    CGContextRef ctx = CGBitmapContextCreate(px, side, side, 8, side * 4, cs,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGContextDrawImage(ctx, CGRectMake(0, 0, side, side), image.CGImage);
    CGContextRelease(ctx);

    double sum = 0, sumSq = 0;
    NSUInteger n = 0;
    for (NSUInteger i = 0; i < side * side; i++) {
        const uint8_t *p = px + i * 4;
        if (p[3] < 16) continue;
        double v = ((double)p[0] * 0.299 + (double)p[1] * 0.587 + (double)p[2] * 0.114) * ((double)p[3] / 255.0);
        sum += v; sumSq += v * v; n++;
    }
    if (n < 16) return nil;
    double mean = sum / (double)n;
    double variance = sumSq / (double)n - mean * mean;
    if (outDeviation) *outDeviation = variance > 0 ? sqrt(variance) : 0;
    return [NSData dataWithBytes:px length:sizeof(px)];
}

static BOOL XCTIconIsUsable(UIImage *image)
{
    if (!image || !image.CGImage) return NO;
    size_t w = CGImageGetWidth(image.CGImage), h = CGImageGetHeight(image.CGImage);
    if (w < 32 || h < 32 || w > 8192 || h > 8192) return NO;
    double deviation = 0;
    NSData *fp = XCTIconPixels(image, &deviation);
    return fp && deviation > 2.5;
}

static CGFloat XCTIconScale(void)
{
    // UIKit scene enumeration is main-thread only; background resolution uses 2.0.
    return NSThread.isMainThread ? (UIScreen.mainScreen.scale ?: 2.0) : 2.0;
}

// MARK: - Disk cache (real icons only)

static NSString *XCTCacheFile(NSString *bid)
{
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
                     stringByAppendingPathComponent:@"XCTAppIcons-v3"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES attributes:nil error:NULL];
    NSMutableString *safe = [NSMutableString stringWithCapacity:96];
    for (NSUInteger i = 0; i < bid.length && i < 80; i++) {
        unichar c = [bid characterAtIndex:i];
        char ch = (c < 128 && (isalnum((int)c) || c == '.' || c == '-' || c == '_')) ? (char)c : '_';
        [safe appendFormat:@"%c", ch];
    }
    uint64_t hash = 1469598103934665603ULL;
    for (NSUInteger i = 0; i < bid.length; i++) {
        hash ^= (uint64_t)[bid characterAtIndex:i];
        hash *= 1099511628211ULL;
    }
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%016llx.png", safe, hash]];
}

void XCTClearAppIconCache(void)
{
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
                     stringByAppendingPathComponent:@"XCTAppIcons-v3"];
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL] ?: @[];
    for (NSString *file in files) {
        NSString *path = [dir stringByAppendingPathComponent:file];
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    }
    wq_log(@"图标缓存已清空（%lu 个文件）", (unsigned long)files.count);
}

// MARK: - Source A: UIKit private API across every format

static UIImage *XCTRawIcon(NSString *bid, int format, CGFloat scale)
{
    if (![UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) return nil;
    @try {
        return [UIImage _applicationIconImageForBundleIdentifier:bid format:format scale:scale];
    } @catch (NSException *exception) {
        return nil;
    }
}

// If Safari, Preferences, Camera and a nonexistent id all produce the exact
// same bitmap, this format is a constant placeholder and must be discarded.
static BOOL XCTFormatIsPlaceholder(int format)
{
    static NSMutableDictionary<NSNumber *, NSNumber *> *verdicts;
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ verdicts = [NSMutableDictionary new]; lock = [NSLock new]; });
    NSNumber *key = @(format);
    [lock lock];
    NSNumber *cached = verdicts[key];
    [lock unlock];
    if (cached) return cached.boolValue;

    NSArray<NSString *> *probes = @[@"com.apple.mobilesafari", @"com.apple.Preferences",
                                    @"com.apple.camera", kXCTUnknownBundle];
    NSMutableArray<NSData *> *prints = [NSMutableArray array];
    for (NSString *probe in probes) {
        NSData *fp = XCTIconPixels(XCTRawIcon(probe, format, 2.0), NULL);
        if (fp) [prints addObject:fp];
    }
    BOOL constant = prints.count >= 3;
    for (NSUInteger i = 1; constant && i < prints.count; i++) {
        if (![prints[i] isEqualToData:prints[0]]) constant = NO;
    }
    [lock lock];
    verdicts[key] = @(constant);
    [lock unlock];
    return constant;
}

static NSData *XCTBlankPrint(int format)
{
    static NSMutableDictionary<NSNumber *, NSData *> *prints;
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ prints = [NSMutableDictionary new]; lock = [NSLock new]; });
    NSNumber *key = @(format);
    [lock lock];
    NSData *value = prints[key];
    [lock unlock];
    if (value) return value;
    NSData *fp = XCTIconPixels(XCTRawIcon(kXCTUnknownBundle, format, 2.0), NULL);
    if (fp) {
        [lock lock];
        prints[key] = fp;
        [lock unlock];
    }
    return fp;
}

static UIImage *XCTUIKitIcon(NSString *bid, NSString **source, NSString **detail)
{
    static NSInteger preferred = -1;
    NSMutableArray<NSNumber *> *formats = [NSMutableArray arrayWithCapacity:10];
    if (preferred >= 0) [formats addObject:@(preferred)];
    for (int f = 0; f <= 8; f++) if (f != preferred) [formats addObject:@(f)];
    NSArray<NSNumber *> *scales = @[@(XCTIconScale()), @2.0, @3.0];
    NSUInteger refused = 0;

    for (NSNumber *formatNumber in formats) {
        int format = formatNumber.intValue;
        if (XCTFormatIsPlaceholder(format)) { refused++; continue; }
        NSData *blank = XCTBlankPrint(format);
        for (NSNumber *scaleNumber in scales) {
            UIImage *raw = XCTRawIcon(bid, format, scaleNumber.doubleValue);
            if (!raw) continue;
            NSData *fp = XCTIconPixels(raw, NULL);
            if (blank && fp && [fp isEqualToData:blank]) continue;
            if (!XCTIconIsUsable(raw)) continue;
            preferred = format;
            *source = [NSString stringWithFormat:@"UIKit fmt%d", format];
            *detail = [NSString stringWithFormat:@"私有图标接口 format=%d scale=%.1f", format, scaleNumber.doubleValue];
            return raw;
        }
    }
    *detail = [NSString stringWithFormat:@"私有接口全部返回占位或拒绝（%lu/9 个 format 为固定占位）", (unsigned long)refused];
    return nil;
}

// MARK: - System icon service

static UIImage *XCTSystemIconData(NSString *bid, NSString **source, NSString **detail)
{
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = XCTInvokeObject(workspaceClass, @"defaultWorkspace", @[]);
    if (!workspace) workspace = XCTInvokeObject(workspaceClass, @"sharedWorkspace", @[]);
    id proxy = nil;
    for (NSString *sel in @[@"applicationForBundleIdentifier:", @"applicationWithBundleIdentifier:",
                            @"applicationForIdentifier:"]) {
        proxy = XCTInvokeObject(workspace, sel, @[bid]);
        if (proxy) break;
    }
    if (proxy) {
        NSArray<NSString *> *selectors = @[@"iconDataForVariant:", @"_iconDataForVariant:",
                                           @"iconDataForVariant:format:", @"iconDataForVariant:withOptions:"];
        for (NSString *sel in selectors) {
            NSUInteger arity = sel.length - [sel stringByReplacingOccurrencesOfString:@":" withString:@""].length;
            for (NSInteger variant = 0; variant < 4; variant++) {
                NSArray *args = arity >= 2 ? @[@(variant), @0] : @[@(variant)];
                id data = XCTInvokeObject(proxy, sel, args);
                if (![data isKindOfClass:NSData.class] || [(NSData *)data length] < 128) continue;
                UIImage *image = [UIImage imageWithData:(NSData *)data scale:2.0];
                if (!XCTIconIsUsable(image)) continue;
                *source = @"LaunchServices";
                *detail = [NSString stringWithFormat:@"iconDataForVariant:%ld（%lu 字节 PNG）",
                           (long)variant, (unsigned long)[(NSData *)data length]];
                return image;
            }
        }
    }

    Class iconCacheClass = NSClassFromString(@"ISIconCache");
    id cache = nil;
    for (NSString *sel in @[@"sharedCache", @"defaultCache", @"sharedInstance"]) {
        cache = XCTInvokeObject(iconCacheClass, sel, @[]);
        if (cache) break;
    }
    for (NSString *sel in @[@"iconForBundleIdentifier:", @"iconImageForBundleIdentifier:",
                            @"cachedIconForBundleIdentifier:"]) {
        XCTInvokeResult result = XCTInvoke(cache, sel, @[bid]);
        UIImage *image = [result.object isKindOfClass:UIImage.class] ? result.object : nil;
        if (!image && result.pointer && CFGetTypeID(result.pointer) == CGImageGetTypeID()) {
            image = [UIImage imageWithCGImage:(CGImageRef)result.pointer scale:2.0
                                  orientation:UIImageOrientationUp];
        }
        if (XCTIconIsUsable(image)) {
            *source = @"IconServices";
            *detail = sel;
            return image;
        }
    }
    *detail = proxy ? @"LS/IS 图标缓存未返回有效位图" : @"LSApplicationWorkspace 不可用";
    return nil;
}

// MARK: - Bundle helpers

static NSData *XCTReadFile(NSString *path, NSUInteger limit)
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length || data.length > limit) {
        wq_grant(path.stringByDeletingLastPathComponent);
        wq_grant(path);
        data = [NSData dataWithContentsOfFile:path];
    }
    return (data.length && data.length <= limit) ? data : nil;
}

static NSDictionary *XCTReadInfo(NSString *bundle)
{
    NSString *path = [bundle stringByAppendingPathComponent:@"Info.plist"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) {
        wq_grant(bundle);
        wq_grant(path);
        data = [NSData dataWithContentsOfFile:path];
    }
    if (!data.length || data.length > 8 * 1024 * 1024) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    return [plist isKindOfClass:NSDictionary.class] ? plist : nil;
}

// Pairs of bundle id -> installed-app info, gathered from LaunchServices and
// the installation database. Used for display names, bundle paths (icons) and
// categories when the vendored LS container database has no names.
static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *XCTWorkspaceApps(void)
{
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *built = [NSMutableDictionary new];
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        id workspace = XCTInvokeObject(workspaceClass, @"defaultWorkspace", @[]);
        if (!workspace) workspace = XCTInvokeObject(workspaceClass, @"sharedWorkspace", @[]);
        NSArray *apps = XCTInvokeObject(workspace, @"allInstalledApplications", @[]);
        if (![apps isKindOfClass:NSArray.class]) apps = XCTInvokeObject(workspace, @"allApplications", @[]);
        if (![apps isKindOfClass:NSArray.class]) apps = @[];
        for (id proxy in apps) {
            NSString *bid = XCTInvokeObject(proxy, @"bundleIdentifier", @[]);
            if (![bid isKindOfClass:NSString.class] || !bid.length) continue;
            NSString *name = XCTInvokeObject(proxy, @"localizedName", @[]);
            if (![name isKindOfClass:NSString.class] || !name.length) {
                name = XCTInvokeObject(proxy, @"itemName", @[]);
            }
            NSString *path = nil;
            id url = XCTInvokeObject(proxy, @"bundleURL", @[]);
            if ([url isKindOfClass:NSURL.class]) path = [(NSURL *)url path];
            if (!path.length) {
                id raw = XCTInvokeObject(proxy, @"bundlePath", @[]);
                if ([raw isKindOfClass:NSString.class]) path = raw;
            }
            NSMutableDictionary *entry = [NSMutableDictionary new];
            if ([name isKindOfClass:NSString.class] && [name length]) entry[@"name"] = name;
            if (path.length) entry[@"path"] = path;
            if (entry.count) built[bid] = entry;
        }
        map = built.copy;
    });
    return map;
}

static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *XCTInstalledApps(void)
{
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *built = [NSMutableDictionary new];
        for (NSString *path in @[@"/private/var/mobile/Library/MobileInstallation/LastLaunchServicesMap.plist",
                                @"/var/mobile/Library/MobileInstallation/LastLaunchServicesMap.plist"]) {
            NSData *data = XCTReadFile(path, 32 * 1024 * 1024);
            if (!data) continue;
            id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
            if (![plist isKindOfClass:NSDictionary.class]) continue;
            for (NSString *scope in @[@"User", @"System"]) {
                NSDictionary *apps = plist[scope];
                if (![apps isKindOfClass:NSDictionary.class]) continue;
                [apps enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *__unused stop) {
                    if (![key isKindOfClass:NSString.class] || ![value isKindOfClass:NSDictionary.class]) return;
                    NSString *appPath = value[@"Path"];
                    if (![appPath isKindOfClass:NSString.class] || ![appPath hasSuffix:@".app"]) return;
                    NSMutableDictionary *entry = [NSMutableDictionary new];
                    entry[@"path"] = appPath;
                    for (NSString *nameKey in @[@"CFBundleDisplayName", @"CFBundleName", @"DisplayName"]) {
                        id name = value[nameKey];
                        if ([name isKindOfClass:NSString.class] && [name length]) {
                            entry[@"name"] = name;
                            break;
                        }
                    }
                    built[key] = entry;
                }];
            }
            if (built.count) break;
        }
        map = built.copy;
    });
    return map;
}

static NSString *XCTBundlePathForID(NSString *bid)
{
    if (!bid.length) return nil;
    NSString *path = XCTWorkspaceApps()[bid][@"path"];
    if (path.length) return path;
    path = XCTInstalledApps()[bid][@"path"];
    if (path.length) return path;
    return wq_bundle_path_for_id(bid);
}

NSString *XCTAppBundlePath(NSString *bundleID)
{
    return XCTBundlePathForID(bundleID);
}

static NSString *XCTKnownAppName(NSString *bid)
{
    if (!bid.length) return nil;
    NSString *name = XCTWorkspaceApps()[bid][@"name"];
    if (name.length) return name;
    return XCTInstalledApps()[bid][@"name"];
}

// MARK: - Rendering

static UIGraphicsImageRenderer *XCTRenderer(void)
{
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 2.0;
    format.opaque = NO;
    return [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(kXCTIconSide, kXCTIconSide) format:format];
}

static UIBezierPath *XCTIconPath(void)
{
    return [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, kXCTIconSide, kXCTIconSide)
                                      cornerRadius:kXCTIconSide * 0.225];
}

static UIImage *XCTRoundIcon(UIImage *raw)
{
    return [XCTRenderer() imageWithActions:^(UIGraphicsImageRendererContext *__unused ctx) {
        [XCTIconPath() addClip];
        [raw drawInRect:CGRectMake(0, 0, kXCTIconSide, kXCTIconSide)];
    }];
}

// Symbol + colour rules, same table as WQ Files' wq_service_tile.
static NSDictionary *XCTTileRule(NSString *bid)
{
    static NSArray<NSArray *> *rules;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIColor *blue = UIColor.systemBlueColor, *green = UIColor.systemGreenColor,
                *red = UIColor.systemRedColor, *orange = UIColor.systemOrangeColor,
                *purple = UIColor.systemPurpleColor, *indigo = UIColor.systemIndigoColor,
                *teal = UIColor.systemTealColor, *pink = UIColor.systemPinkColor,
                *gray = UIColor.systemGrayColor;
        rules = @[
            @[@[@"emoji"], @"face.smiling.inverse", orange],
            @[@[@"keyboard", @"inputui", @"textinput", @"dictation"], @"keyboard.fill", gray],
            @[@[@"airdrop", @"sharing", @"sharesheet"], @"antenna.radiowaves.left.and.right", blue],
            @[@[@"widget", @"chrono"], @"square.grid.2x2.fill", blue],
            @[@[@"screenshot", @"screencapture", @"screenrecord"], @"camera.viewfinder", indigo],
            @[@[@"poster", @"wallpaper"], @"photo.on.rectangle.angled", purple],
            @[@[@"siri", @"assistant"], @"waveform", indigo],
            @[@[@"camera"], @"camera.fill", gray],
            @[@[@"photo"], @"photo.fill", orange],
            @[@[@"music", @"audio", @"shazam", @"musicrecognition"], @"music.note", pink],
            @[@[@"headphone", @"airpods", @"bluetooth"], @"headphones", gray],
            @[@[@"hearing"], @"ear.fill", blue],
            @[@[@"weather"], @"cloud.sun.fill", teal],
            @[@[@"location", @"maps", @"navigation"], @"location.fill", blue],
            @[@[@"health", @"fitness", @"workout"], @"heart.fill", red],
            @[@[@"pay", @"wallet", @"passbook", @"cash", @"finance"], @"creditcard.fill", green],
            @[@[@"mail"], @"envelope.fill", blue],
            @[@[@"message", @"sms", @"imessage"], @"message.fill", green],
            @[@[@"facetime", @"video"], @"video.fill", green],
            @[@[@"phone", @"call", @"telephony"], @"phone.fill", green],
            @[@[@"notification", @"usernotification", @"bulletin"], @"bell.fill", red],
            @[@[@"shortcut", @"workflow", @"intent"], @"square.on.square", indigo],
            @[@[@"safari", @"web"], @"safari.fill", blue],
            @[@[@"news", @"stocks"], @"newspaper.fill", red],
            @[@[@"calendar", @"event"], @"calendar", red],
            @[@[@"note", @"paper"], @"note.text", orange],
            @[@[@"reminder"], @"checklist", blue],
            @[@[@"game"], @"gamecontroller.fill", purple],
            @[@[@"auth", @"account", @"appsso", @"password", @"keychain", @"tcc", @"privacy"], @"lock.fill", gray],
            @[@[@"print"], @"printer.fill", gray],
            @[@[@"clarity", @"accessib"], @"accessibility", blue],
            @[@[@"home"], @"house.fill", orange],
            @[@[@"findmy", @"fmd", @"fmip"], @"location.circle.fill", green],
            @[@[@"carplay", @"carradio", @"cartrip", @"car."], @"car.fill", gray],
            @[@[@"tvremote", @"tvsetup", @"com.apple.tv"], @"tv.fill", gray],
            @[@[@"book"], @"book.fill", orange],
            @[@[@"podcast"], @"mic.fill", purple],
            @[@[@"spotlight", @"search"], @"magnifyingglass", gray],
            @[@[@"diagnostic", @"logging", @"crash", @"analytics"], @"stethoscope", gray],
            @[@[@"font"], @"textformat", gray],
            @[@[@"translate"], @"character.bubble.fill", blue],
            @[@[@"file", @"document", @"cloud"], @"folder.fill", blue],
            @[@[@"setup", @"buddy", @"onboarding"], @"gearshape.2.fill", gray],
        ];
    });
    NSString *key = bid.lowercaseString;
    for (NSArray *rule in rules) {
        for (NSString *word in rule[0]) {
            if ([key containsString:word]) {
                return @{ @"symbol": rule[1], @"color": rule[2] };
            }
        }
    }
    return @{ @"symbol": @"gearshape.fill", @"color": UIColor.systemGrayColor };
}

static UIImage *XCTServiceTile(NSString *bid)
{
    static NSCache *tiles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ tiles = [NSCache new]; });
    NSDictionary *rule = XCTTileRule(bid);
    NSString *symbolName = rule[@"symbol"];
    UIColor *color = rule[@"color"];
    NSString *cacheKey = [symbolName stringByAppendingString:color.description];
    UIImage *cached = [tiles objectForKey:cacheKey];
    if (cached) return cached;

    const CGFloat s = 40;
    UIColor *fill = [color resolvedColorWithTraitCollection:
                     [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight]];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(s, s)];
    UIImage *tile = [renderer imageWithActions:^(UIGraphicsImageRendererContext *__unused ctx) {
        [fill setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, s, s) cornerRadius:s * 0.225] fill];
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:19
                                                                                             weight:UIImageSymbolWeightSemibold];
        UIImage *glyph = [[UIImage systemImageNamed:symbolName withConfiguration:config] ?:
                          [UIImage systemImageNamed:@"gearshape.fill" withConfiguration:config]
                          imageWithTintColor:UIColor.whiteColor
                          renderingMode:UIImageRenderingModeAlwaysOriginal];
        [glyph drawInRect:CGRectMake((s - glyph.size.width) / 2, (s - glyph.size.height) / 2,
                                     glyph.size.width, glyph.size.height)];
    }];
    [tiles setObject:tile forKey:cacheKey];
    return tile;
}

// MARK: - Public resolution

static NSData *XCTResolveBody(NSString *bid, BOOL force)
{
    if (!bid.length) return nil;
    static NSCache<NSString *, NSData *> *memory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        memory = [NSCache new];
        memory.countLimit = 256;
    });
    NSString *file = XCTCacheFile(bid);
    if (!force) {
        NSData *hit = [memory objectForKey:bid];
        if (hit) return hit;
        NSData *disk = [NSData dataWithContentsOfFile:file];
        if (disk.length) {
            [memory setObject:disk forKey:bid];
            return disk;
        }
    }

    NSString *source = @"占位图";
    NSString *detail = @"系统没有返回可用图标";
    NSString *reasonA = @"", *reasonB = @"";
    UIImage *raw = XCTUIKitIcon(bid, &source, &reasonA);
    if (!raw) {
        NSString *systemSource = source;
        raw = XCTSystemIconData(bid, &systemSource, &reasonB);
        if (raw) {
            source = systemSource;
            detail = reasonB;
        }
    }
    if (!raw) {
        NSArray<NSString *> *parts = [bid componentsSeparatedByString:@"."];
        for (NSInteger n = (NSInteger)parts.count - 1; !raw && n >= 3; n--) {
            NSString *parent = [[parts subarrayWithRange:NSMakeRange(0, (NSUInteger)n)] componentsJoinedByString:@"."];
            NSString *parentSource = source;
            raw = XCTUIKitIcon(parent, &parentSource, &reasonA);
            if (raw) {
                source = @"父应用图标";
                detail = [NSString stringWithFormat:@"%@ → %@", parent, parentSource];
            }
        }
    }
    if (raw && [source hasPrefix:@"UIKit"]) detail = reasonA;
    if (raw && ([source isEqualToString:@"LaunchServices"] || [source isEqualToString:@"IconServices"])) detail = reasonB;
    if (!raw) detail = [NSString stringWithFormat:@"A:%@ | B:%@", reasonA, reasonB];

    UIImage *icon = raw ? XCTRoundIcon(raw) : XCTServiceTile(bid);
    NSData *png = UIImagePNGRepresentation(icon);
    if (png) {
        [memory setObject:png forKey:bid];
        if (raw) [png writeToFile:file atomically:YES];
        else [[NSFileManager defaultManager] removeItemAtPath:file error:NULL];
    }
    return png;
}

static NSData *XCTResolve(NSString *bid, BOOL force)
{
    NSData *result = nil;
    @autoreleasepool {
        result = XCTResolveBody(bid, force);
    }
    return result;
}

NSData *XCTAppIconPNG(NSString *bundleID)
{
    return XCTResolve(bundleID, NO);
}

NSData *XCTAppIconPNGForce(NSString *bundleID)
{
    return XCTResolve(bundleID, YES);
}

void XCTWarmAppIcons(NSArray<NSString *> *bundleIDs)
{
    for (NSString *bid in bundleIDs) {
        @autoreleasepool {
            if (bid.length) (void)XCTResolve(bid, NO);
        }
    }
}

// MARK: - Display name & category

// Localized value from <bundle>/<lang>.lproj/InfoPlist.strings, falling back
// to the raw Info.plist key.
static NSString *XCTLocalizedName(NSString *bundle, NSDictionary *info, NSString *key)
{
    if (bundle.length) {
        wq_grant(bundle);
        NSBundle *appBundle = [NSBundle bundleWithPath:bundle];
        NSString *localized = [appBundle localizedStringForKey:key value:@"" table:@"InfoPlist"];
        if (localized.length) return localized;
    }
    id raw = info[key];
    return [raw isKindOfClass:NSString.class] && [raw length] ? raw : nil;
}

static NSDictionary *XCTReadAppStoreMetadata(NSString *bundle)
{
    if (!bundle.length) return nil;
    NSString *path = [bundle stringByAppendingPathComponent:@"iTunesMetadata.plist"];
    NSData *data = XCTReadFile(path, 4 * 1024 * 1024);
    if (!data) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    return [plist isKindOfClass:NSDictionary.class] ? plist : nil;
}

// LSApplicationProxy carries the same localized name the home screen shows.
static NSString *XCTProxyName(NSString *bid)
{
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = XCTInvokeObject(workspaceClass, @"defaultWorkspace", @[]);
    if (!workspace) workspace = XCTInvokeObject(workspaceClass, @"sharedWorkspace", @[]);
    if (!workspace) return nil;
    for (NSString *sel in @[@"applicationProxyForIdentifier:", @"applicationForBundleIdentifier:",
                            @"applicationWithBundleIdentifier:", @"applicationForIdentifier:"]) {
        id proxy = XCTInvokeObject(workspace, sel, @[bid]);
        if (!proxy) continue;
        for (NSString *key in @[@"localizedName", @"itemName", @"displayName"]) {
            id value = XCTInvokeObject(proxy, key, @[]);
            if ([value isKindOfClass:NSString.class] && [(NSString *)value length]) return value;
        }
    }
    return nil;
}

static NSString *XCTCategoryFromType(NSString *type)
{
    if (![type isKindOfClass:NSString.class] || !type.length) return nil;
    static NSDictionary<NSString *, NSString *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"public.app-category.games": @"游戏",
            @"public.app-category.social-networking": @"社交",
            @"public.app-category.shopping": @"购物",
            @"public.app-category.utilities": @"工具",
            @"public.app-category.productivity": @"效率",
            @"public.app-category.entertainment": @"娱乐",
            @"public.app-category.music": @"音乐",
            @"public.app-category.photo-video": @"摄影与录像",
            @"public.app-category.photography": @"摄影与录像",
            @"public.app-category.news": @"新闻",
            @"public.app-category.finance": @"财务",
            @"public.app-category.education": @"教育",
            @"public.app-category.lifestyle": @"生活",
            @"public.app-category.healthcare-fitness": @"健康健美",
            @"public.app-category.travel": @"旅游",
            @"public.app-category.food-and-drink": @"美食佳饮",
            @"public.app-category.navigation": @"导航",
            @"public.app-category.business": @"商务",
            @"public.app-category.developer-tools": @"开发者工具",
            @"public.app-category.graphics-design": @"图形与设计",
            @"public.app-category.medical": @"医疗",
            @"public.app-category.books": @"图书",
            @"public.app-category.reference": @"参考",
            @"public.app-category.sports": @"体育",
            @"public.app-category.weather": @"天气",
            @"public.app-category.magazines-newspapers": @"报刊杂志",
        };
    });
    NSString *name = table[type];
    if (name) return name;
    // Unknown sub-category: keep the last dash segment readable.
    NSString *tail = type.pathExtension;
    return tail.length > 3 ? tail : nil;
}

// App Store genre first (already localized), then the bundle's declared
// category, then a system / third-party split so every row has a label.
static NSString *XCTAppCategory(NSString *bid, NSDictionary *info, NSDictionary *meta)
{
    id genre = meta[@"genre"];
    if ([genre isKindOfClass:NSString.class] && [(NSString *)genre length]) return genre;

    for (NSString *key in @[@"LSApplicationCategoryType", @"ApplicationCategoryType"]) {
        NSString *name = XCTCategoryFromType(info[key]);
        if (name) return name;
    }
    if ([bid hasPrefix:@"com.apple."]) return @"系统";
    return @"第三方";
}

NSDictionary<NSString *, NSString *> *XCTAppIdentity(NSString *bundleID)
{
    if (!bundleID.length) return @{ @"name": @"", @"category": @"" };

    static NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *cache;
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
        lock = [NSLock new];
    });

    [lock lock];
    NSDictionary<NSString *, NSString *> *cached = cache[bundleID];
    [lock unlock];
    if (cached) return cached;

    NSString *bundle = XCTBundlePathForID(bundleID);
    if (bundle.length) wq_grant(bundle);
    NSDictionary *info = bundle.length ? XCTReadInfo(bundle) : nil;
    NSDictionary *meta = XCTReadAppStoreMetadata(bundle);

    NSString *name = wq_display_name(bundleID);
    if (!name.length || [name isEqualToString:bundleID]) {
        id itemName = meta[@"itemName"];
        name = XCTKnownAppName(bundleID)
            ?: XCTProxyName(bundleID)
            ?: XCTLocalizedName(bundle, info, @"CFBundleDisplayName")
            ?: XCTLocalizedName(bundle, info, @"CFBundleName")
            ?: ([itemName isKindOfClass:NSString.class] && [itemName length] ? itemName : nil)
            ?: bundleID;
    }

    NSDictionary<NSString *, NSString *> *result = @{
        @"name": name ?: bundleID,
        @"category": XCTAppCategory(bundleID, info, meta) ?: @"",
    };
    [lock lock];
    cache[bundleID] = result;
    [lock unlock];
    return result;
}
