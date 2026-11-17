// Minimal container-access adapter built on WQ Files 0.9.5 (kolbicz/WQFiles).
// Sandbox technique: worse_query by Taj C (forcequit), GPL-3.0-or-later.
// See THIRD_PARTY_NOTICES.md for vendored sources and licenses.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XCTContainerBridge : NSObject

// The App Group entitlement actually present in the running signature.
+ (NSString * _Nullable)appGroup;

// Runtime OS version and support verdict (worse_query works on iOS 26 / 27).
+ (NSString *)systemVersion;
+ (BOOL)containerAccessAvailable;

// Allow/deny the expensive fsgetpath inode scan. Defaults to allowed:
// on iOS 26 the LaunchServices database itself is located by an inode scan,
// so denying it can leave the app list empty.
+ (void)setFullScanAllowed:(BOOL)allowed NS_SWIFT_NAME(setFullScanAllowed(_:));
+ (BOOL)fullScanAllowed;
+ (void)stopFullScan NS_SWIFT_NAME(stopFullScan());

// Enumerate application data containers that can be granted and identified.
// Each record: id, name, path, category.
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)applications:(BOOL)refresh NS_SWIFT_NAME(applications(refresh:));

// Container paths found by the last enumeration, and whether the last scan
// was declined by the confirm hook.
+ (NSInteger)lastContainerCount;
+ (BOOL)lastScanWasDeclined;

// Ask for a sandbox extension covering `path` (and its parent when needed).
+ (BOOL)prepareRead:(NSString *)path NS_SWIFT_NAME(prepareRead(path:));

// List one directory inside a granted container.
// Each record: name, path, kind (dir/file/link/other), bytes, stat.
+ (NSArray<NSDictionary<NSString *, id> *> *)listDirectory:(NSString *)path NS_SWIFT_NAME(listDirectory(path:));
+ (NSString * _Nullable)directoryReadError:(NSString *)path;

// Lightweight access health check. Returns display-ready key/value rows.
+ (NSDictionary<NSString *, NSString *> *)runSelfCheck NS_SWIFT_NAME(runSelfCheck());

// Repair a broken App Group Library/Caches swap (upstream wq_reset_access_cache).
// Returns nil on success, otherwise the reason.
+ (NSString * _Nullable)resetAccessCache NS_SWIFT_NAME(resetAccessCache());

// Forget the remembered LaunchServices database so the next scan looks again.
+ (void)forgetLaunchServicesStore NS_SWIFT_NAME(forgetLaunchServicesStore());

+ (NSData * _Nullable)iconPNGForBundleID:(NSString *)bundleID NS_SWIFT_NAME(iconPNG(bundleID:));

// Resolve icons again (ignoring caches) and report which source produced
// each one. Each row: id, source, detail.
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)probeIcons:(NSArray<NSString *> *)bundleIDs
    NS_SWIFT_NAME(probeIcons(_:));
+ (void)clearIconCache NS_SWIFT_NAME(clearIconCache());
+ (BOOL)catalogIconsEnabled;
+ (void)setCatalogIconsEnabled:(BOOL)enabled NS_SWIFT_NAME(setCatalogIconsEnabled(_:));

+ (NSString *)diagnostics;
+ (NSString * _Nullable)lastError;

@end

NS_ASSUME_NONNULL_END
