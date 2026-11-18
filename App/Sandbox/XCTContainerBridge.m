// Minimal container-access adapter built on WQ Files 0.9.5 (kolbicz/WQFiles).
// Sandbox technique: worse_query by Taj C (forcequit), GPL-3.0-or-later.
// See THIRD_PARTY_NOTICES.md for vendored sources and licenses.
#import "XCTContainerBridge.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "XCTAppMetadata.h"
#import <UIKit/UIKit.h>
#import <dirent.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>

static BOOL gXCTFullScanAllowed = YES;      // upstream confirms full scans in UI; allow by default here
static NSString *_Nullable gXCTLastError = nil;
static NSArray<NSString *> *_Nullable gXCTContainers = nil;
static NSInteger gXCTContainerCount = 0;
static NSLock *gXCTStateLock = nil;

static BOOL XCTConfirmScan(NSString *what, int64_t ids, double seconds)
{
    BOOL allowed = gXCTFullScanAllowed;
    wq_log(@"扫描确认 %@ | %lld 个文件 ID | 约 %.0f 秒 | %@", what, (long long)ids, seconds,
           allowed ? @"允许" : @"拒绝");
    return allowed;
}

static void XCTScanProgress(int64_t done, int64_t total, BOOL finished)
{
    wq_log(@"扫描进度 %lld/%lld%@", (long long)done, (long long)total, finished ? @" 完成" : @"");
}

// WQ Files registers these three hooks in main(), before UIApplicationMain.
// A SwiftUI @main app has no explicit main(), so a dyld constructor does it
// at image load time, which is even earlier and equally global.
__attribute__((constructor))
static void XCTContainerBridgeBootstrap(void)
{
    gXCTStateLock = [NSLock new];
    wq_set_container_label_resolver(wq_bundle_id_for_container);
    wq_set_container_list_provider(wq_ls_container_paths);
    wq_set_full_scan_ui(XCTConfirmScan, XCTScanProgress);
}

static void XCTSetError(NSString *text)
{
    gXCTLastError = text;
    wq_log(@"%@", text);
}

static NSArray<NSString *> *XCTSamplePaths(NSArray<NSString *> *paths, NSUInteger count)
{
    NSString *home = [NSHomeDirectory() stringByResolvingSymlinksInPath];
    NSMutableArray<NSString *> *others = [NSMutableArray array];
    for (NSString *p in paths) {
        if (![[p stringByResolvingSymlinksInPath] isEqualToString:home]) [others addObject:p];
    }
    if (others.count <= count) return others;
    NSMutableArray<NSString *> *picked = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) [picked addObject:others[i * others.count / count]];
    return picked;
}

@implementation XCTContainerBridge

+ (NSString * _Nullable)appGroup { return wq_app_group(); }
+ (NSString *)diagnostics { return wq_log_text() ?: @""; }
+ (NSString * _Nullable)lastError { return gXCTLastError; }
+ (NSData * _Nullable)iconPNGForBundleID:(NSString *)bundleID { return XCTAppIconPNG(bundleID); }

+ (NSString * _Nullable)bundlePathForBundleID:(NSString *)bundleID
{
    if (!bundleID.length) return nil;
    NSString *path = wq_bundle_path_for_id(bundleID);
    if (path.length && [path hasSuffix:@".app"]) return path;

    // LaunchServices proxy fallback (private, but already used for icons).
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (proxyClass) {
        @try {
            id proxy = [proxyClass performSelector:@selector(applicationProxyForIdentifier:)
                                        withObject:bundleID];
            if ([proxy respondsToSelector:@selector(bundlePath)]) {
                id raw = [proxy performSelector:@selector(bundlePath)];
                if ([raw isKindOfClass:NSString.class] && [raw hasSuffix:@".app"]) return raw;
            }
            if ([proxy respondsToSelector:@selector(bundleURL)]) {
                id url = [proxy performSelector:@selector(bundleURL)];
                if ([url isKindOfClass:NSURL.class]) {
                    NSString *p = [(NSURL *)url path];
                    if ([p hasSuffix:@".app"]) return p;
                }
            }
        } @catch (__unused NSException *e) {}
    }
    return nil;
}
+ (void)clearIconCache { XCTClearAppIconCache(); }
+ (BOOL)catalogIconsEnabled { return XCTCatalogIconsEnabled(); }
+ (void)setCatalogIconsEnabled:(BOOL)enabled { XCTSetCatalogIconsEnabled(enabled); }

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)probeIcons:(NSArray<NSString *> *)bundleIDs
{
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *rows = [NSMutableArray array];
    for (NSString *bid in bundleIDs) {
        if (!bid.length) continue;
        @autoreleasepool {
            (void)XCTAppIconPNGForce(bid);
            NSDictionary<NSString *, NSString *> *fact = XCTIconFact(bid) ?: @{};
            [rows addObject:@{ @"id": bid,
                               @"source": fact[@"source"] ?: @"未知",
                               @"detail": fact[@"detail"] ?: @"" }];
        }
    }
    return rows;
}

+ (NSString *)systemVersion
{
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    return [NSString stringWithFormat:@"%ld.%ld.%ld", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion];
}

+ (BOOL)containerAccessAvailable
{
    // Check the running OS directly instead of @available: the binary may be
    // built with an older SDK, where the compile-time check is unreliable.
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26;
}

+ (void)setFullScanAllowed:(BOOL)allowed { gXCTFullScanAllowed = allowed; }
+ (BOOL)fullScanAllowed { return gXCTFullScanAllowed; }
+ (void)stopFullScan { wq_full_scan_stop(); wq_log(@"已请求停止完整扫描"); }
+ (NSInteger)lastContainerCount { return gXCTContainerCount; }
+ (BOOL)lastScanWasDeclined { return wq_full_scan_was_declined(); }

+ (NSString * _Nullable)resetAccessCache
{
    NSString *reason = nil;
    if (wq_reset_access_cache(&reason)) {
        wq_log(@"访问缓存已修复");
        return nil;
    }
    return reason ?: @"未知错误";
}

+ (void)forgetLaunchServicesStore
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:@"WQLaunchServicesStore"];
    [defaults removeObjectForKey:@"WQLaunchServicesStoreMissedAt"];
    wq_display_names_reset_miss();
    wq_enumerate_invalidate();
    wq_log(@"已清除记住的 LaunchServices 数据库位置，下次扫描会重新查找");
}

// A directory-scoped extension is not enough to stat/open a child two levels
// down, so grant the parent first and then the item itself.
+ (BOOL)prepareRead:(NSString *)path
{
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    int openCode = fd < 0 ? errno : 0;
    if (fd >= 0) close(fd);
    struct stat st;
    int metadataCode = lstat(path.fileSystemRepresentation, &st) == 0 ? 0 : errno;
    if (!openCode && !metadataCode) return YES;
    if (openCode != EPERM && openCode != EACCES && metadataCode != EPERM && metadataCode != EACCES) return NO;

    NSString *parent = path.stringByDeletingLastPathComponent;
    BOOL parentGrant = wq_grant(parent);
    fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    openCode = fd < 0 ? errno : 0;
    if (fd >= 0) close(fd);
    metadataCode = lstat(path.fileSystemRepresentation, &st) == 0 ? 0 : errno;
    BOOL itemGrant = NO;
    if (openCode || metadataCode) {
        itemGrant = wq_grant(path);
        fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        openCode = fd < 0 ? errno : 0;
        if (fd >= 0) close(fd);
        metadataCode = lstat(path.fileSystemRepresentation, &st) == 0 ? 0 : errno;
    }
    wq_log(@"访问 %@ | parent grant=%@ | item grant=%@ | open errno=%d (%s) | lstat errno=%d (%s)",
           path, parentGrant ? @"YES" : @"NO", itemGrant ? @"YES" : @"NO",
           openCode, strerror(openCode), metadataCode, strerror(metadataCode));
    return !openCode && !metadataCode;
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)applications:(BOOL)refresh
{
    gXCTLastError = nil;
#if TARGET_OS_SIMULATOR
    XCTSetError(@"模拟器不支持跨应用容器发现，请在 iOS 26+ 真机运行。");
    return @[];
#else
    if (![self containerAccessAvailable]) {
        XCTSetError([NSString stringWithFormat:@"容器访问要求 iOS 26 或更新版本，当前系统为 %@。", [self systemVersion]]);
        return @[];
    }
    NSString *group = wq_app_group();
    if (!group) {
        XCTSetError(@"签名未提供 App Group。重签时必须使用保留 com.apple.security.application-groups 的工具（AltStore / SideStore / Impactor 或带 App Groups 能力的描述文件）。");
        return @[];
    }

    // WQ Files order: invalidate -> enumerate -> load display names. Loading
    // names first can consume the one-shot LaunchServices store search.
    if (refresh) {
        wq_display_names_reset_miss();
        wq_enumerate_invalidate();
    }
    NSArray<NSString *> *paths = wq_enumerate(@"/private/var/mobile/Containers/Data/Application", 0, nil,
        ^(int64_t done, int64_t total, NSUInteger found) {
            wq_log(@"容器扫描 %lld/%lld | 已找到 %lu 个", (long long)done, (long long)total, (unsigned long)found);
        });
    gXCTContainerCount = (NSInteger)(paths ? paths.count : 0);
    [gXCTStateLock lock];
    gXCTContainers = paths;
    [gXCTStateLock unlock];

    if (!paths.count) {
        NSString *hint = wq_full_scan_was_declined()
            ? @"完整 inode 扫描被拒绝；到「设置」打开「允许完整扫描」后重试。"
            : @"检查签名 App Group、系统版本，或先运行「重置访问缓存」。";
        XCTSetError([NSString stringWithFormat:@"没有取得应用容器列表（%@）。%@", group, hint]);
        return @[];
    }
    if (!wq_display_names_loaded()) wq_load_display_names();

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *result = [NSMutableArray array];
    for (NSString *path in paths) {
        NSString *identifier = wq_container_label(path);
        if (!identifier.length) continue;
        if (!wq_grant(path)) continue;
        NSDictionary<NSString *, NSString *> *identity = XCTAppIdentity(identifier);
        NSString *name = identity[@"name"];
        if (!name.length) name = identifier;
        [result addObject:@{ @"id": identifier, @"name": name, @"path": path,
                             @"category": identity[@"category"] ?: @"" }];
    }
    if (!result.count) XCTSetError([NSString stringWithFormat:@"找到 %lu 个容器路径，但没有一个能取得 token 或身份标识。请查看日志中的 grant / enumerate 行。",
                                    (unsigned long)paths.count]);
    return result;
#endif
}

+ (NSDictionary<NSString *, NSString *> *)runSelfCheck
{
    NSMutableDictionary<NSString *, NSString *> *report = [NSMutableDictionary dictionary];
    NSString *group = wq_app_group();
    report[@"App Group"] = group ?: @"缺失（重签丢失了 entitlement）";
    report[@"系统版本"] = [self systemVersion];
    report[@"系统支持"] = [self containerAccessAvailable] ? @"iOS 26+ 支持" : @"需要 iOS 26+";
    report[@"完整扫描"] = gXCTFullScanAllowed ? @"允许" : @"禁止";
    report[@"上次扫描被拒"] = wq_full_scan_was_declined() ? @"是" : @"否";

    NSString *base = @"/private/var/mobile/Containers/Data/Application";
    int fd = open(base.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd >= 0) {
        close(fd);
        report[@"容器父目录"] = @"可直接打开";
    } else {
        int code = errno;
        report[@"容器父目录"] = [NSString stringWithFormat:@"拒绝 errno=%d (%s)", code, strerror(code)];
    }

    NSString *store = [NSUserDefaults.standardUserDefaults stringForKey:@"WQLaunchServicesStore"];
    report[@"LS 数据库"] = store.length ? store : @"尚未定位（首次扫描会查找）";
    NSArray<NSString *> *lsPaths = wq_ls_container_paths(nil);
    report[@"LS 记录"] = [NSString stringWithFormat:@"%lu 个容器路径", (unsigned long)(lsPaths ? lsPaths.count : 0)];
    report[@"应用名称库"] = wq_display_names_loaded() ? @"已加载" : @"未加载";

    [gXCTStateLock lock];
    NSArray<NSString *> *cached = gXCTContainers;
    [gXCTStateLock unlock];
    report[@"上次枚举"] = [NSString stringWithFormat:@"%ld 个容器", (long)gXCTContainerCount];

    NSArray<NSString *> *sample = XCTSamplePaths(cached ?: @[], 8);
    NSUInteger opened = 0, labeled = 0;
    NSMutableArray<NSString *> *refused = [NSMutableArray array];
    for (NSString *path in sample) {
        NSString *reason = nil;
        if (wq_grant(path) && wq_list(path, &reason)) opened++;
        else [refused addObject:[NSString stringWithFormat:@"%@ (%@)", path.lastPathComponent, reason ?: @"NO TOKEN"]];
        if (wq_container_label(path).length) labeled++;
    }
    if (sample.count) {
        report[@"抽样容器"] = [NSString stringWithFormat:@"%lu 个", (unsigned long)sample.count];
        report[@"可读取"] = [NSString stringWithFormat:@"%lu / %lu", (unsigned long)opened, (unsigned long)sample.count];
        report[@"可识别"] = [NSString stringWithFormat:@"%lu / %lu", (unsigned long)labeled, (unsigned long)sample.count];
        if (refused.count) report[@"被拒样本"] = [refused componentsJoinedByString:@", "];
    } else {
        report[@"抽样容器"] = @"无（先在「文件」页刷新一次）";
    }
    return report;
}

+ (NSArray<NSDictionary<NSString *, id> *> *)listDirectory:(NSString *)path
{
    gXCTLastError = nil;
    if (!wq_app_group()) {
        XCTSetError(@"签名未提供 App Group，容器访问不可用。");
        return @[];
    }
    if (![self prepareRead:path]) {
        NSString *detail = [self directoryReadError:path];
        XCTSetError(detail ?: [NSString stringWithFormat:@"无法取得目录授权：%@", path]);
        return @[];
    }
    NSString *reason = nil;
    NSArray<NSString *> *names = wq_list(path, &reason);
    if (!names) {
        XCTSetError(reason ?: [NSString stringWithFormat:@"目录读取失败：%@", path]);
        return @[];
    }
    NSMutableArray<NSDictionary<NSString *, id> *> *rows = [NSMutableArray arrayWithCapacity:names.count];
    for (NSString *name in names) {
        if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) continue;
        NSString *child = [path stringByAppendingPathComponent:name];
        struct stat st;
        BOOL known = wq_stat(child, &st);
        if (!known) {
            // Cold container: the first touch of a foreign container on iOS 26
            // still answers EPERM until the item itself has been round-tripped
            // through a grant. prepareRead is nearly free once the parent is
            // already openable, and the retry keeps subdirectories from
            // silently disappearing out of the directory browser.
            [self prepareRead:child];
            known = wq_stat(child, &st);
        }
        NSString *kind = @"other";
        uint64_t bytes = 0;
        if (known) {
            if (S_ISDIR(st.st_mode)) kind = @"dir";
            else if (S_ISREG(st.st_mode)) { kind = @"file"; bytes = (uint64_t)st.st_size; }
            else if (S_ISLNK(st.st_mode)) kind = @"link";
        }
        // mtime/ext are returned as raw data; ordering is a UI concern and
        // lives in Swift (SortPreferences), so a directory can be re-sorted
        // without asking WQAccess for another sandbox extension.
        double mtime = known ? (double)st.st_mtime : 0.0;
        [rows addObject:@{ @"name": name, @"path": child, @"kind": kind,
                           @"bytes": @(bytes), @"stat": known ? @"YES" : @"NO",
                           @"mtime": @(mtime), @"ext": name.pathExtension.lowercaseString ?: @"" }];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL ad = [a[@"kind"] isEqualToString:@"dir"], bd = [b[@"kind"] isEqualToString:@"dir"];
        if (ad != bd) return ad ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];
    return rows;
}

+ (NSString * _Nullable)directoryReadError:(NSString *)path
{
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return [NSString stringWithFormat:@"%@ | open errno=%d (%s)", path, errno, strerror(errno)];
    DIR *dir = fdopendir(fd);
    if (!dir) { int code = errno; close(fd); return [NSString stringWithFormat:@"%@ | fdopendir errno=%d (%s)", path, code, strerror(code)]; }
    errno = 0;
    readdir(dir);
    int code = errno;
    closedir(dir);
    if (code) return [NSString stringWithFormat:@"%@ | readdir errno=%d (%s)", path, code, strerror(code)];
    return nil;
}

@end
