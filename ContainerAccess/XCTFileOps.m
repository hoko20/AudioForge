// File operations + per-app access-type enumeration built on WQ Files 0.9.5.
// Sandbox technique: worse_query by Taj C (forcequit), GPL-3.0-or-later.
#import "XCTFileOps.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import <UIKit/UIKit.h>
#import <sys/stat.h>
#import <dirent.h>
#import <fcntl.h>
#import <unistd.h>
#import <copyfile.h>
#import <compression.h>
#import <pwd.h>
#import <grp.h>
#import <limits.h>

// MARK: - CRC32 (for store-only ZIP)

static uint32_t gXCTCRC32Table[256];
static BOOL gXCTCRC32Ready = NO;

static void XCTCRC32Init(void) {
    for (uint32_t n = 0; n < 256; n++) {
        uint32_t c = n;
        for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320U ^ (c >> 1)) : (c >> 1);
        gXCTCRC32Table[n] = c;
    }
    gXCTCRC32Ready = YES;
}

static uint32_t XCTCRC32(const void *buf, size_t len) {
    if (!gXCTCRC32Ready) XCTCRC32Init();
    uint32_t crc = 0xFFFFFFFFU;
    const unsigned char *p = buf;
    for (size_t i = 0; i < len; i++) crc = gXCTCRC32Table[(crc ^ p[i]) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFU;
}

// MARK: - Helpers

static NSString *XCTErr(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    return s;
}

static NSString *XCTPathOf(NSString *base, NSString *name) {
    return [base stringByAppendingPathComponent:name];
}

// Best-effort grant of the item itself and any .app bundle it sits inside, so
// reading files from an installed application bundle (read-only) also works.
static void XCTGrantForRead(NSString *path) {
    if (!path.length) return;
    wq_grant([path stringByDeletingLastPathComponent]);
    wq_grant(path);
    NSArray<NSString *> *parts = path.pathComponents;
    for (NSString *part in parts) {
        if ([part hasSuffix:@".app"]) {
            NSUInteger idx = [parts indexOfObject:part];
            NSString *bundle = [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0, idx + 1)]];
            wq_grant(bundle);
        }
    }
}

// `stat` that survives a cold container. wq_stat() already retries once after
// granting the parent, but the very first touch of a foreign container on
// iOS 26 still comes back EPERM: the token has to be round-tripped the same way
// a read does before metadata is handed out. Without this, "信息" failed until
// the user happened to tap 导出 first (which performs a real read and leaves the
// container granted for the rest of the run).
static BOOL XCTStatDeep(NSString *path, struct stat *st) {
    if (!path.length) return NO;
    if (wq_stat(path, st)) return YES;
    XCTGrantForRead(path);
    if (wq_stat(path, st)) return YES;
    NSString *reason = nil;
    wq_list([path stringByDeletingLastPathComponent], &reason);  // completes the container grant
    if (wq_stat(path, st)) return YES;
    NSString *err = nil;
    wq_read(path, 1, &err);   // harmless on a directory, finishes a file grant
    return wq_stat(path, st);
}

static NSString *XCTModeString(mode_t mode) {
    char s[11] = "----------";
    if (S_ISDIR(mode)) s[0] = 'd';
    else if (S_ISLNK(mode)) s[0] = 'l';
    else if (S_ISCHR(mode)) s[0] = 'c';
    else if (S_ISBLK(mode)) s[0] = 'b';
    else if (S_ISFIFO(mode)) s[0] = 'p';
    else if (S_ISSOCK(mode)) s[0] = 's';
    const char *rwx = "rwxrwxrwx";
    for (int i = 0; i < 9; i++) if (mode & (1 << (8 - i))) s[i + 1] = rwx[i];
    if (mode & S_ISUID) s[3] = (s[3] == 'x') ? 's' : 'S';
    if (mode & S_ISGID) s[6] = (s[6] == 'x') ? 's' : 'S';
    if (mode & S_ISVTX) s[9] = (s[9] == 'x') ? 't' : 'T';
    return [NSString stringWithUTF8String:s];
}

static NSString *XCTAccountName(id who, BOOL group) {
    char buf[512];
    if (group) {
        struct group g, *res = NULL;
        if (getgrgid_r([who unsignedIntValue], &g, buf, sizeof(buf), &res) == 0 && res && res->gr_name)
            return [NSString stringWithUTF8String:res->gr_name];
    } else {
        struct passwd p, *res = NULL;
        if (getpwuid_r([who unsignedIntValue], &p, buf, sizeof(buf), &res) == 0 && res && res->pw_name)
            return [NSString stringWithUTF8String:res->pw_name];
    }
    return nil;
}

// Best-effort recursive size, capped so a huge tree can't hang the UI thread.
static int64_t XCTRecursiveSize(NSString *path, NSUInteger *counter, NSUInteger limit) {
    struct stat st;
    if (!XCTStatDeep(path, &st)) return 0;
    if (*counter >= limit) return 0;
    (*counter)++;
    if (S_ISDIR(st.st_mode)) {
        int64_t total = 0;
        NSString *reason = nil;
        NSArray<NSString *> *names = wq_list(path, &reason);
        for (NSString *name in names) {
            if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) continue;
            total += XCTRecursiveSize(XCTPathOf(path, name), counter, limit);
            if (*counter >= limit) break;
        }
        return total;
    }
    return (int64_t)st.st_size;
}

// MARK: - Suffix filter

// Case-insensitive "ends with any of these". Entries may be given with or
// without a leading dot, so @".aud_tmp" and @"aud_tmp" behave the same.
// Note ".aud" does NOT match "2..aud_tmp", which is what the replace tool
// relies on to keep the two lists apart.
static BOOL XCTNameMatches(NSString *name, NSArray<NSString *> *suffixes) {
    if (suffixes.count == 0) return YES;
    NSString *lower = name.lowercaseString;
    for (NSString *raw in suffixes) {
        if (![raw isKindOfClass:[NSString class]] || !raw.length) continue;
        NSString *s = raw.lowercaseString;
        if (![s hasPrefix:@"."]) s = [@"." stringByAppendingString:s];
        if ([lower hasSuffix:s]) return YES;
    }
    return NO;
}

// Rejects path traversal and normalises an archive entry into a safe relative
// path ("./a//b" -> "a/b"). Returns nil when the entry escapes the extraction
// directory.
static NSString *XCTSafeRelativePath(NSString *entry) {
    if (!entry.length) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *c in [entry componentsSeparatedByString:@"/"]) {
        if (!c.length || [c isEqualToString:@"."]) continue;
        if ([c isEqualToString:@".."]) return nil;
        [parts addObject:c];
    }
    return parts.count ? [parts componentsJoinedByString:@"/"] : nil;
}

static uint16_t XCTLE16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static uint32_t XCTLE32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

// Best-effort directory walk. `budget` caps the number of directories opened
// so pointing the tool at a huge tree cannot hang the background thread.
static void XCTCollectFiles(NSString *dir, NSString *root, NSArray<NSString *> *suffixes,
                            BOOL deep, NSMutableArray<NSDictionary<NSString *, id> *> *out,
                            NSUInteger *budget, NSInteger depth) {
    if (*budget == 0 || depth > 8 || !dir.length) return;
    (*budget)--;
    NSString *reason = nil;
    NSArray<NSString *> *names = wq_list(dir, &reason);
    if (!names) return;
    for (NSString *name in names) {
        if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) continue;
        NSString *full = XCTPathOf(dir, name);
        struct stat st;
        if (!XCTStatDeep(full, &st)) continue;
        if (S_ISDIR(st.st_mode)) {
            if (deep) XCTCollectFiles(full, root, suffixes, deep, out, budget, depth + 1);
            continue;
        }
        if (!S_ISREG(st.st_mode)) continue;
        if (!XCTNameMatches(name, suffixes)) continue;

        NSString *prefix = [root hasSuffix:@"/"] ? root : [root stringByAppendingString:@"/"];
        NSString *rel = [full hasPrefix:prefix] ? [full substringFromIndex:prefix.length] : name;
        [out addObject:@{
            @"name": name,
            @"path": full,
            @"dir": dir,
            @"relative": rel,
            @"bytes": [NSNumber numberWithLongLong:(long long)st.st_size],
            @"mtime": [NSNumber numberWithDouble:(double)st.st_mtimespec.tv_sec],
        }];
    }
}

@implementation XCTFileOps

// MARK: - Access types (Filza-style "访问类型")

+ (NSArray<NSDictionary<NSString *, id> *> *)accessTypesForContainer:(NSString *)containerPath
                                                          bundleID:(NSString *)bundleID {
    NSMutableArray<NSDictionary<NSString *, id> *> *out = [NSMutableArray array];
    if (!containerPath.length) return out;

    NSArray<NSArray *> *standard = @[
        @[@"App 数据", containerPath, @"data"],
        @[@"Documents", XCTPathOf(containerPath, @"Documents"), @"docs"],
        @[@"Library", XCTPathOf(containerPath, @"Library"), @"library"],
        @[@"tmp", XCTPathOf(containerPath, @"tmp"), @"tmp"],
    ];
    for (NSArray *row in standard) {
        [out addObject:@{ @"label": row[0], @"path": row[1], @"kind": row[2], @"readOnly": @NO }];
    }

    NSString *bundle = nil;
    if (bundleID.length) bundle = wq_bundle_path_for_id(bundleID);
    if (bundle.length) {
        [out addObject:@{ @"label": @"App 安装包 (.app)", @"path": bundle, @"kind": @"bundle", @"readOnly": @YES }];
    }

    // App Group containers are reachable through the app's own
    // Library/Group Containers symlinks — no extra entitlements required.
    NSString *groupDir = XCTPathOf(XCTPathOf(containerPath, @"Library"), @"Group Containers");
    if (wq_grant(groupDir)) {
        NSString *reason = nil;
        NSArray<NSString *> *names = wq_list(groupDir, &reason);
        for (NSString *gid in names) {
            if ([gid isEqualToString:@"."] || [gid isEqualToString:@".."]) continue;
            NSString *link = XCTPathOf(groupDir, gid);
            NSString *target = [[NSFileManager defaultManager] destinationOfSymbolicLinkAtPath:link error:nil];
            if (!target.length) {
                struct stat st;
                if (XCTStatDeep(link, &st) && S_ISDIR(st.st_mode)) target = link;
            }
            if (!target.length) continue;
            [out addObject:@{ @"label": [NSString stringWithFormat:@"App Group: %@", gid],
                              @"path": target, @"kind": @"group", @"readOnly": @NO }];
        }
    }
    return out;
}

// MARK: - File operations

+ (NSString * _Nullable)renameItemAt:(NSString *)path toName:(NSString *)name {
    if (!path.length || !name.length) return @"缺少路径或新名称";
    NSString *err = nil;
    if (wq_rename(path, name, &err)) return nil;
    return err ?: @"重命名失败";
}

+ (NSString * _Nullable)deleteItemAt:(NSString *)path {
    if (!path.length) return @"缺少路径";
    struct stat st;
    BOOL isDir = (XCTStatDeep(path, &st) && S_ISDIR(st.st_mode));
    NSString *err = nil;
    if (isDir) {
        // wq_delete removes a single item; refuse a non-empty directory so we
        // never silently truncate another app's data.
        NSString *reason = nil;
        NSArray<NSString *> *children = wq_list(path, &reason);
        if (children.count > 0) {
            return [NSString stringWithFormat:@"目录非空（%lu 项）。请先清空，或在文件管理器中整体移动。",
                    (unsigned long)children.count];
        }
    }
    if (wq_delete(path, &err)) return nil;
    return err ?: @"删除失败";
}

// POSIX copy that never touches the metadata API, so it keeps working on a
// container that has only just been granted. NSFileManager's -copyItemAtPath:
// enumerates extended attributes and fails in exactly that state.
static BOOL XCTCopyDeep(NSString *src, NSString *dst) {
    if (!src.length || !dst.length) return NO;
    XCTGrantForRead(src);
    XCTGrantForRead([dst stringByDeletingLastPathComponent]);
    const uint32_t flags = COPYFILE_DATA | COPYFILE_STAT;
    if (copyfile(src.fileSystemRepresentation, dst.fileSystemRepresentation, NULL, flags) == 0) return YES;
    if (errno == EEXIST || errno == ENOTEMPTY)
        return copyfile(src.fileSystemRepresentation, dst.fileSystemRepresentation, NULL,
                        flags | COPYFILE_UNLINK) == 0;
    return NO;
}

+ (NSString * _Nullable)copyItemAt:(NSString *)path toPath:(NSString *)destPath {
    if (!path.length || !destPath.length) return @"缺少源或目标路径";
    XCTGrantForRead(path);
    XCTGrantForRead([destPath stringByDeletingLastPathComponent]);
    wq_grant([path stringByDeletingLastPathComponent]);
    wq_grant([destPath stringByDeletingLastPathComponent]);
    NSError *e = nil;
    if ([[NSFileManager defaultManager] copyItemAtPath:path toPath:destPath error:&e]) return nil;
    if (XCTCopyDeep(path, destPath)) return nil;
    return e.localizedDescription ?: XCTErr(@"复制失败（errno=%d %s）", errno, strerror(errno));
}

+ (NSString * _Nullable)moveItemAt:(NSString *)path toDirectory:(NSString *)destDir {
    if (!path.length || !destDir.length) return @"缺少源或目标目录";
    NSString *dest = XCTPathOf(destDir, path.lastPathComponent);
    // wq_move does a same-volume rename with the grants the move needs; an
    // explicit name/inode-preserving path beats NSFileManager here.
    NSString *err = nil;
    if (wq_move(path, destDir, &err)) return nil;
    XCTGrantForRead(path);
    wq_grant(destDir);
    NSError *e = nil;
    if ([[NSFileManager defaultManager] moveItemAtPath:path toPath:dest error:&e]) return nil;
    return err.length ? err : (e.localizedDescription ?: @"移动失败");
}

+ (NSString * _Nullable)createDirectoryAt:(NSString *)path {
    if (!path.length) return @"缺少路径";
    NSString *err = nil;
    if (wq_create_dir(path, &err)) return nil;
    return err ?: @"创建目录失败";
}

+ (NSString * _Nullable)createFileAt:(NSString *)path text:(NSString *)text {
    if (!path.length) return @"缺少路径";
    NSData *data = [text ?: @"" dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSString *err = nil;
    if (wq_create_file(path, data, &err)) return nil;
    return err ?: @"创建文件失败";
}

+ (NSString * _Nullable)writeTextAt:(NSString *)path text:(NSString *)text {
    if (!path.length) return @"缺少路径";
    NSData *data = [text ?: @"" dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSString *err = nil;
    if (wq_write(path, data, &err)) return nil;
    return err ?: @"写入失败";
}

+ (NSDictionary<NSString *, NSString *> *)readTextAt:(NSString *)path maxBytes:(NSUInteger)maxBytes {
    if (!path.length) return @{ @"error": @"缺少路径" };
    XCTGrantForRead(path);
    NSString *err = nil;
    NSData *data = wq_read(path, maxBytes, &err);
    if (!data) return @{ @"error": (err ?: @"读取失败") };
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!text) return @{ @"error": @"无法解码为文本（可能是二进制文件）" };
    return @{ @"text": text };
}

+ (NSDictionary<NSString *, id> *)readDataAt:(NSString *)path maxBytes:(NSUInteger)maxBytes {
    if (!path.length) return @{ @"error": @"缺少路径" };
    XCTGrantForRead(path);
    NSString *err = nil;
    NSData *data = wq_read(path, maxBytes, &err);
    if (!data) return @{ @"error": (err ?: @"读取失败") };
    return @{ @"data": data };
}

+ (NSDictionary<NSString *, NSString *> *)attributesAt:(NSString *)path {
    NSMutableDictionary<NSString *, NSString *> *d = [NSMutableDictionary dictionary];
    if (!path.length) { d[@"error"] = @"缺少路径"; return d; }

    // POSIX stat instead of NSFileManager: -attributesOfItemAtPath: also pulls
    // extended attributes, which needs read-data on the container and therefore
    // failed on a container that had only been listed, never read.
    struct stat st;
    if (!XCTStatDeep(path, &st)) {
        int err = errno;
        d[@"error"] = XCTErr(@"读取属性失败（errno=%d %s）", err, strerror(err));
        return d;
    }

    mode_t mode = st.st_mode;
    d[@"类型"] = S_ISDIR(mode) ? @"文件夹"
               : S_ISLNK(mode) ? @"符号链接"
               : S_ISREG(mode) ? @"文件"
               : S_ISCHR(mode) ? @"字符设备"
               : S_ISBLK(mode) ? @"块设备"
               : S_ISFIFO(mode) ? @"管道"
               : S_ISSOCK(mode) ? @"套接字" : @"未知";

    NSByteCountFormatter *sizeFmt = [[NSByteCountFormatter alloc] init];
    sizeFmt.countStyle = NSByteCountFormatterCountStyleFile;
    d[@"大小"] = [NSString stringWithFormat:@"%@（%lld 字节）",
                  [sizeFmt stringFromByteCount:(long long)st.st_size], (long long)st.st_size];
    if (S_ISREG(mode) && st.st_blocks > 0) {
        d[@"占用空间"] = [sizeFmt stringFromByteCount:(long long)st.st_blocks * 512];
    }

    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateStyle = NSDateFormatterMediumStyle;
    f.timeStyle = NSDateFormatterMediumStyle;
    if (st.st_mtimespec.tv_sec > 0)
        d[@"修改时间"] = [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:st.st_mtimespec.tv_sec]];
    if (st.st_birthtimespec.tv_sec > 0)
        d[@"创建时间"] = [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:st.st_birthtimespec.tv_sec]];
    if (st.st_ctimespec.tv_sec > 0)
        d[@"状态变更"] = [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:st.st_ctimespec.tv_sec]];

    d[@"权限"] = [NSString stringWithFormat:@"%04o %@", (unsigned)(mode & 07777), XCTModeString(mode)];

    NSString *owner = XCTAccountName(@(st.st_uid), NO);
    NSString *group = XCTAccountName(@(st.st_gid), YES);
    d[@"所有者"] = owner.length ? [NSString stringWithFormat:@"%@ (%u)", owner, st.st_uid]
                                : [NSString stringWithFormat:@"%u", st.st_uid];
    d[@"所属组"] = group.length ? [NSString stringWithFormat:@"%@ (%u)", group, st.st_gid]
                                : [NSString stringWithFormat:@"%u", st.st_gid];

    d[@"硬链接"] = [NSString stringWithFormat:@"%u", st.st_nlink];
    d[@"inode"] = [NSString stringWithFormat:@"%llu", (unsigned long long)st.st_ino];

    if (S_ISLNK(mode)) {
        char buf[PATH_MAX];
        ssize_t n = readlink(path.fileSystemRepresentation, buf, sizeof(buf) - 1);
        if (n > 0) { buf[n] = '\0'; d[@"链接目标"] = [NSString stringWithUTF8String:buf]; }
        struct stat target;
        if (stat(path.fileSystemRepresentation, &target) == 0) {
            d[@"链接有效"] = @"是";
            d[@"目标类型"] = S_ISDIR(target.st_mode) ? @"文件夹" : @"文件";
        } else {
            d[@"链接有效"] = @"否（目标不可达）";
        }
    }

    d[@"完整路径"] = path;
    return d;
}

+ (NSString * _Nullable)setModeAt:(NSString *)path mode:(NSInteger)mode {
    if (!path.length) return @"缺少路径";
    wq_grant([path stringByDeletingLastPathComponent]);
    if (chmod(path.fileSystemRepresentation, (mode_t)mode) == 0) return nil;
    return XCTErr(@"chmod 失败 errno=%d (%s)", errno, strerror(errno));
}

+ (NSString * _Nullable)makeSymlinkAt:(NSString *)path target:(NSString *)target {
    if (!path.length || !target.length) return @"缺少路径或目标";
    wq_grant([path stringByDeletingLastPathComponent]);
    if (symlink(target.fileSystemRepresentation, path.fileSystemRepresentation) == 0) return nil;
    return XCTErr(@"symlink 失败 errno=%d (%s)", errno, strerror(errno));
}

+ (NSNumber * _Nullable)sizeAt:(NSString *)path {
    if (!path.length) return nil;
    NSUInteger counter = 0;
    int64_t s = XCTRecursiveSize(path, &counter, 20000);
    return @(s);
}

// MARK: - Store-only ZIP writer

+ (NSString * _Nullable)zipItemsAtPaths:(NSArray<NSString *> *)paths to:(NSString *)destPath {
    if (!paths.count || !destPath.length) return @"缺少源或目标";
    wq_grant([destPath stringByDeletingLastPathComponent]);

    NSMutableData *central = [NSMutableData data];
    NSMutableData *body = [NSMutableData data];

    // 16-bit DOS time/date for the optional extra field; keeps unzip happy.
    NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    NSDateComponents *c = [cal components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay|
                                      NSCalendarUnitHour|NSCalendarUnitMinute|NSCalendarUnitSecond
                                    fromDate:[NSDate date]];
    UInt16 dosTime = (UInt16)((c.hour << 11) | (c.minute << 5) | (c.second / 2));
    UInt16 dosDate = (UInt16)(((c.year - 1980) << 9) | (c.month << 5) | c.day);

    NSInteger entries = 0;
    for (NSString *src in paths) {
        if (!src.length) continue;
        wq_grant([src stringByDeletingLastPathComponent]);
        struct stat st;
        if (!XCTStatDeep(src, &st)) continue;
        BOOL isDir = S_ISDIR(st.st_mode);
        NSString *name = src.lastPathComponent;
        if (isDir) name = [name stringByAppendingString:@"/"];
        NSData *content = isDir ? [NSData data] : ({
            NSString *err = nil;
            wq_read(src, (NSUInteger)st.st_size, &err) ?: [NSData data];
        });
        UInt32 crc = XCTCRC32(content.bytes, content.length);

        // Local file header (signature 0x04034b50).
        NSMutableData *local = [NSMutableData data];
        UInt32 off = (UInt32)body.length;
        [local appendBytes:"PK\3\4" length:4];
        [local appendBytes:&(UInt16){20} length:2];      // version needed
        [local appendBytes:&(UInt16){0} length:2];       // flags
        [local appendBytes:&(UInt16){0} length:2];       // method = store
        [local appendBytes:&dosTime length:2];
        [local appendBytes:&dosDate length:2];
        [local appendBytes:&crc length:4];
        [local appendBytes:&(UInt32){content.length} length:4]; // compressed
        [local appendBytes:&(UInt32){content.length} length:4]; // uncompressed
        [local appendBytes:&(UInt16){name.length} length:2];
        [local appendBytes:&(UInt16){0} length:2];       // extra len
        [local appendData:[name dataUsingEncoding:NSUTF8StringEncoding]];
        [local appendData:content];
        [body appendData:local];

        // Central directory record (signature 0x02014b50).
        NSMutableData *cd = [NSMutableData data];
        [cd appendBytes:"PK\1\2" length:4];
        [cd appendBytes:&(UInt16){20} length:2];         // version made by
        [cd appendBytes:&(UInt16){20} length:2];         // version needed
        [cd appendBytes:&(UInt16){0} length:2];
        [cd appendBytes:&(UInt16){0} length:2];          // method store
        [cd appendBytes:&dosTime length:2];
        [cd appendBytes:&dosDate length:2];
        [cd appendBytes:&crc length:4];
        [cd appendBytes:&(UInt32){content.length} length:4];
        [cd appendBytes:&(UInt32){content.length} length:4];
        [cd appendBytes:&(UInt16){name.length} length:2];
        [cd appendBytes:&(UInt16){0} length:2];
        [cd appendBytes:&(UInt16){0} length:2];
        [cd appendBytes:&(UInt16){0} length:2];
        [cd appendBytes:&(UInt16){0} length:2];
        [cd appendBytes:&(UInt32){0} length:4];          // external attrs
        [cd appendBytes:&off length:4];                  // local header offset
        [cd appendData:[name dataUsingEncoding:NSUTF8StringEncoding]];
        [central appendData:cd];
        entries++;
    }

    NSMutableData *outData = [NSMutableData data];
    [outData appendData:body];
    [outData appendData:central];
    // End of central directory (signature 0x06054b50).
    UInt16 e16 = 0; UInt32 e32 = 0;
    [outData appendBytes:"PK\5\6" length:4];
    [outData appendBytes:&e16 length:2];
    [outData appendBytes:&e16 length:2];
    [outData appendBytes:&(UInt16){entries} length:2];
    [outData appendBytes:&(UInt16){entries} length:2];
    [outData appendBytes:&(UInt32){central.length} length:4];
    [outData appendBytes:&(UInt32){body.length} length:4];
    [outData appendBytes:&e16 length:2];

    if (wq_create_file(destPath, outData, nil)) return nil;
    return @"ZIP 写出失败";
}

// MARK: - Replace-file tool support

+ (NSArray<NSDictionary<NSString *, id> *> *)listFilesAt:(NSString *)dir
                                                suffixes:(NSArray<NSString *> *)suffixes
                                               recursive:(BOOL)recursive {
    NSMutableArray<NSDictionary<NSString *, id> *> *out = [NSMutableArray array];
    if (!dir.length) return out;
    wq_grant(dir);
    NSUInteger budget = 4000;
    XCTCollectFiles(dir, dir, suffixes ?: @[], recursive, out, &budget, 0);
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [(NSString *)a[@"relative"] localizedStandardCompare:(NSString *)b[@"relative"]];
    }];
    return out;
}

+ (NSString * _Nullable)overwriteFileAt:(NSString *)destPath withFileAt:(NSString *)sourcePath {
    if (!destPath.length || !sourcePath.length) return @"缺少源或目标路径";
    if ([destPath isEqualToString:sourcePath]) return @"源文件和目标文件是同一个";

    struct stat src;
    if (!XCTStatDeep(sourcePath, &src)) return @"读不到源文件（没有访问权限或文件已不存在）";
    if (!S_ISREG(src.st_mode)) return @"源不是普通文件";
    if (src.st_size <= 0) return @"源文件是空文件，已中止";

    struct stat dst;
    if (!XCTStatDeep(destPath, &dst)) return @"目标文件不存在（列表可能已过期，请刷新）";
    if (!S_ISREG(dst.st_mode)) return @"目标不是普通文件";

    // Source is usually inside another container, so grant before opening it.
    // The destination side is granted by wq_write_from_file itself.
    XCTGrantForRead(sourcePath);
    wq_grant([destPath stringByDeletingLastPathComponent]);
    wq_grant(destPath);

    NSString *err = nil;
    if (!wq_write_from_file(destPath, sourcePath, &err)) {
        return err.length ? err : @"覆盖失败（写入被拒绝）";
    }

    // wq_write_from_file truncates + streams; confirm the size really landed.
    struct stat after;
    if (XCTStatDeep(destPath, &after) && after.st_size != src.st_size) {
        return [NSString stringWithFormat:@"写入后大小不一致（期望 %lld，实际 %lld）",
                (long long)src.st_size, (long long)after.st_size];
    }
    return nil;
}

+ (NSDictionary<NSString *, id> *)unzipArchiveAt:(NSString *)archivePath
                                         intoDir:(NSString *)destDir
                                        suffixes:(NSArray<NSString *> *)suffixes {
    if (!archivePath.length || !destDir.length) return @{ @"error": @"缺少压缩包或输出目录" };

    NSData *zip = [NSData dataWithContentsOfFile:archivePath
                                         options:NSDataReadingMappedIfSafe
                                           error:NULL];
    if (zip.length < 22) return @{ @"error": @"读不到压缩包（文件太小或无法访问）" };
    const uint8_t *b = zip.bytes;
    NSUInteger len = zip.length;

    // End of central directory: scan back through the (up to 64 KB) comment.
    NSInteger eocd = -1;
    NSUInteger from = len > 66000 ? len - 66000 : 0;
    for (NSInteger i = (NSInteger)len - 22; i >= (NSInteger)from; i--) {
        if (b[i] == 0x50 && b[i + 1] == 0x4B && b[i + 2] == 0x05 && b[i + 3] == 0x06) { eocd = i; break; }
    }
    if (eocd < 0) return @{ @"error": @"不是有效的 ZIP / IPA 包（未找到中央目录）" };

    uint16_t entryCount = XCTLE16(b + eocd + 10);
    uint32_t cdOffset = XCTLE32(b + eocd + 16);
    if ((NSUInteger)cdOffset + 46 > len) return @{ @"error": @"ZIP 结构损坏（中央目录越界）" };

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:NULL]) {
        return @{ @"error": @"无法创建解包目录" };
    }

    NSMutableArray<NSString *> *written = [NSMutableArray array];
    NSInteger skipped = 0;
    NSUInteger cursor = cdOffset;

    for (uint16_t i = 0; i < entryCount; i++) {
        if (cursor + 46 > len) break;
        if (!(b[cursor] == 0x50 && b[cursor + 1] == 0x4B &&
              b[cursor + 2] == 0x01 && b[cursor + 3] == 0x02)) break;

        uint16_t method    = XCTLE16(b + cursor + 10);
        uint32_t csize     = XCTLE32(b + cursor + 20);
        uint32_t usize     = XCTLE32(b + cursor + 24);
        uint16_t nameLen   = XCTLE16(b + cursor + 28);
        uint16_t extraLen  = XCTLE16(b + cursor + 30);
        uint16_t commLen   = XCTLE16(b + cursor + 32);
        uint32_t localOff  = XCTLE32(b + cursor + 42);

        if (cursor + 46 + nameLen > len) break;
        NSString *entryName = [[NSString alloc] initWithBytes:(b + cursor + 46)
                                                      length:nameLen
                                                    encoding:NSUTF8StringEncoding];
        cursor += (NSUInteger)46 + nameLen + extraLen + commLen;

        if (!entryName.length) continue;
        if ([entryName hasSuffix:@"/"]) continue;                    // directory entry
        if ([entryName hasPrefix:@"__MACOSX/"]) continue;
        // Filter on the file name only, so ".aud" matches "Audio/x.aud".
        if (!XCTNameMatches(entryName.lastPathComponent, suffixes ?: @[])) continue;

        // ZIP64 sizes and absurd expansions are skipped rather than trusted.
        if (csize == 0xFFFFFFFFu || usize == 0xFFFFFFFFu) { skipped++; continue; }
        if (usize > (256u << 20)) { skipped++; continue; }

        NSString *safe = XCTSafeRelativePath(entryName);
        if (!safe.length) { skipped++; continue; }

        if ((NSUInteger)localOff + 30 > len) { skipped++; continue; }
        if (!(b[localOff] == 0x50 && b[localOff + 1] == 0x4B &&
              b[localOff + 2] == 0x03 && b[localOff + 3] == 0x04)) { skipped++; continue; }

        uint16_t lNameLen  = XCTLE16(b + localOff + 26);
        uint16_t lExtraLen = XCTLE16(b + localOff + 28);
        NSUInteger dataOff = (NSUInteger)localOff + 30 + lNameLen + lExtraLen;
        if (dataOff + csize > len) { skipped++; continue; }

        NSData *content = nil;
        if (method == 0) {
            content = [zip subdataWithRange:NSMakeRange(dataOff, csize)];
        } else if (method == 8) {
            if (usize == 0) {
                content = [NSData data];
            } else {
                uint8_t *dst = malloc(usize);
                if (!dst) { skipped++; continue; }
                // COMPRESSION_ZLIB in libcompression is raw DEFLATE, exactly
                // what ZIP method 8 stores (no zlib header / adler32).
                size_t got = compression_decode_buffer(dst, usize, b + dataOff, csize,
                                                       NULL, COMPRESSION_ZLIB);
                if (got == 0) {
                    free(dst);
                    skipped++;
                    continue;
                }
                content = [NSData dataWithBytes:dst length:got];
                free(dst);
            }
        } else {
            skipped++;                       // bzip2 / lzma / deflate64
            continue;
        }

        NSString *outPath = [destDir stringByAppendingPathComponent:safe];
        [fm createDirectoryAtPath:[outPath stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES
                       attributes:nil
                            error:NULL];
        NSError *writeError = nil;
        if ([content writeToFile:outPath options:NSDataWritingAtomic error:&writeError]) {
            [written addObject:outPath];
        } else {
            skipped++;
        }
    }

    if (written.count == 0) {
        return @{ @"error": skipped > 0
                      ? @"包内匹配的文件都无法解出（可能是 ZIP64 或使用了不支持的压缩算法）"
                      : @"包内没有 .aud / .amr 文件" };
    }
    return @{ @"files": written };
}

@end
