// File operations + per-app access-type enumeration built on WQ Files 0.9.5.
// Sandbox technique: worse_query by Taj C (forcequit), GPL-3.0-or-later.
// Write paths are granted by the underlying wq_* helpers before mutation, so
// callers only pass the path and receive nil (success) or an error string.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XCTFileOps : NSObject

/// Filza-style "访问类型" for one app container. Derived entirely from the
/// granted data container plus LaunchServices bundle lookup and the app's own
/// Library/Group Containers symlinks (so no extra entitlements are needed).
/// Each record: label, path, kind (data|docs|library|tmp|bundle|group), readOnly (BOOL).
+ (NSArray<NSDictionary<NSString *, id> *> *)accessTypesForContainer:(NSString *)containerPath
                                                          bundleID:(NSString *)bundleID
    NS_SWIFT_NAME(accessTypes(containerPath:bundleID:));

/// File operations. Return nil on success, otherwise a human-readable error.
+ (NSString * _Nullable)renameItemAt:(NSString *)path toName:(NSString *)name
    NS_SWIFT_NAME(renameItem(at:toName:));
+ (NSString * _Nullable)deleteItemAt:(NSString *)path
    NS_SWIFT_NAME(deleteItem(at:));
+ (NSString * _Nullable)copyItemAt:(NSString *)path toPath:(NSString *)destPath
    NS_SWIFT_NAME(copyItem(at:toPath:));
+ (NSString * _Nullable)moveItemAt:(NSString *)path toDirectory:(NSString *)destDir
    NS_SWIFT_NAME(moveItem(at:toDirectory:));
+ (NSString * _Nullable)createDirectoryAt:(NSString *)path
    NS_SWIFT_NAME(createDirectory(at:));
+ (NSString * _Nullable)createFileAt:(NSString *)path text:(NSString *)text
    NS_SWIFT_NAME(createFile(at:text:));
+ (NSString * _Nullable)writeTextAt:(NSString *)path text:(NSString *)text
    NS_SWIFT_NAME(writeText(at:text:));

/// Returns @{ @"text": NSString, @"error": NSString }. One of the two is nil.
+ (NSDictionary<NSString *, NSString *> *)readTextAt:(NSString *)path maxBytes:(NSUInteger)maxBytes
    NS_SWIFT_NAME(readText(at:maxBytes:));

/// Raw bytes. Returns @{ @"data": NSData, @"error": NSString }. One of the
/// two is nil. Used for image previews where the sandbox path is not directly
/// readable by UIKit (we copy the bytes across the bridge first).
+ (NSDictionary<NSString *, id> *)readDataAt:(NSString *)path maxBytes:(NSUInteger)maxBytes
    NS_SWIFT_NAME(readData(at:maxBytes:));

/// Human-readable attributes: size, mtime, mode (octal), owner, group, type,
/// and symlink target when applicable.
+ (NSDictionary<NSString *, NSString *> *)attributesAt:(NSString *)path
    NS_SWIFT_NAME(attributes(at:));

+ (NSString * _Nullable)setModeAt:(NSString *)path mode:(NSInteger)mode
    NS_SWIFT_NAME(setMode(at:mode:));
+ (NSString * _Nullable)makeSymlinkAt:(NSString *)path target:(NSString *)target
    NS_SWIFT_NAME(makeSymlink(at:target:));

/// Store-only ZIP (no compression) of the given source paths into `destPath`.
+ (NSString * _Nullable)zipItemsAtPaths:(NSArray<NSString *> *)paths to:(NSString *)destPath
    NS_SWIFT_NAME(zipItems(atPaths:to:));

/// Lists regular files in `dir` whose lowercase name ends with any entry of
/// `suffixes` (@".aud_tmp", @".aud", @".amr" ...). An empty array means every
/// regular file. Directories are never returned. `recursive` walks
/// subdirectories (depth and budget capped). Records carry: name, path, dir,
/// relative, bytes (NSNumber int64) and mtime (NSNumber, Unix seconds).
+ (NSArray<NSDictionary<NSString *, id> *> *)listFilesAt:(NSString *)dir
                                                suffixes:(NSArray<NSString *> *)suffixes
                                               recursive:(BOOL)recursive
    NS_SWIFT_NAME(listFiles(at:suffixes:recursive:));

/// Replaces the *content* of `destPath` with the bytes of `sourcePath`.
///
/// The destination keeps its own name, inode and permission bits — the
/// underlying wq_write_from_file truncates the existing file, streams the new
/// bytes in and keeps a backup, so an app holding an open handle on the file
/// still sees the replacement. This is what the "替换文件" tool needs: a
/// freshly imported `ring.amr` is written into `2..aud_tmp` without renaming
/// the destination. Returns nil on success, otherwise an error string.
+ (NSString * _Nullable)overwriteFileAt:(NSString *)destPath withFileAt:(NSString *)sourcePath
    NS_SWIFT_NAME(overwriteFile(at:withFileAt:));

/// Extracts the matching entries of a ZIP / IPA archive (stored + deflated)
/// into `destDir`, keeping the archive's relative paths. Only entries whose
/// file name ends with one of `suffixes` are decoded, so a multi-hundred-MB
/// IPA only costs the audio it contains. Deflate is handled by libcompression.
/// Returns @{ @"files": @[absolute paths] } or @{ @"error": NSString }.
+ (NSDictionary<NSString *, id> *)unzipArchiveAt:(NSString *)archivePath
                                         intoDir:(NSString *)destDir
                                        suffixes:(NSArray<NSString *> *)suffixes
    NS_SWIFT_NAME(unzipArchive(at:into:suffixes:));

/// Recursive byte size (capped) for info display.
+ (NSNumber * _Nullable)sizeAt:(NSString *)path
    NS_SWIFT_NAME(size(at:));

@end

NS_ASSUME_NONNULL_END
