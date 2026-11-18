// App icon lookup for iOS 26.x. iOS 26 no longer hands app icons to third-party
// processes, so only the system/private UIKit path is attempted; apps without
// a usable icon get a neutral tile.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A 48 pt rounded PNG for the bundle id, cached in memory and on disk.
// Never nil for a non-empty id: falls back to a neutral symbol tile.
NSData * _Nullable XCTAppIconPNG(NSString * _Nullable bundleID);

// Re-resolve ignoring every cache.
NSData * _Nullable XCTAppIconPNGForce(NSString * _Nullable bundleID);

// Warm the cache off the main thread after a container scan.
void XCTWarmAppIcons(NSArray<NSString *> *bundleIDs);

// Drop memory + disk icon caches (diagnostics / settings).
void XCTClearAppIconCache(void);

// Display metadata for an app container: @{ @"name": ..., @"category": ... }.
// Name chain: LaunchServices name (WQ Files tables/LS database) -> LS proxy
// localizedName -> localized CFBundleDisplayName/CFBundleName -> App Store
// iTunesMetadata itemName -> bundle id. Category comes from the App Store
// genre, then LSApplicationCategoryType, then system/third-party.
// Cached per bundle id for the process.
NSDictionary<NSString *, NSString *> *XCTAppIdentity(NSString * _Nullable bundleID);

// Installed .app bundle path for a bundle id. Tries LaunchServices workspace,
// the MobileInstallation map, then the WQ Files database. Nil if unknown.
NSString * _Nullable XCTAppBundlePath(NSString * _Nullable bundleID);

NS_ASSUME_NONNULL_END
