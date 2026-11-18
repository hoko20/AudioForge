// 缓存清理适配层：基于 WQ Files 0.9.16 的 wq_measure_tree / wq_purge_contents。
#import "XCTCacheOps.h"
#import "WQAccess.h"
#import <sys/stat.h>

@implementation XCTCacheOps

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)cacheTargetsForContainer:(NSString *)containerPath
{
    if (!containerPath.length) return @[];

    NSArray<NSArray<NSString *> *> *wanted = @[
        @[@"缓存", @"Library/Caches"],
        @[@"临时文件", @"tmp"],
        @[@"日志", @"Library/Logs"],
    ];

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *out = [NSMutableArray array];
    for (NSArray<NSString *> *pair in wanted) {
        NSString *path = [containerPath stringByAppendingPathComponent:pair[1]];
        struct stat st;
        if (!wq_stat(path, &st) || !S_ISDIR(st.st_mode)) continue;
        [out addObject:@{ @"kind": pair[0], @"title": pair[0], @"path": path }];
    }
    return out;
}

+ (NSNumber *)measureTree:(NSString *)path
{
    if (!path.length) return @0;
    unsigned long long bytes = 0;
    if (wq_measure_tree(path, nil, &bytes) == WQMeasureResultMissing) return @0;
    return @(bytes);
}

+ (NSDictionary<NSString *, id> *)purgeContentsOf:(NSString *)path
{
    if (!path.length) return @{ @"error": @"缺少路径" };
    unsigned long long freed = 0;
    if (wq_purge_contents(path, &freed)) return @{ @"freed": @(freed) };
    return @{ @"error": @"目录无法读取，或部分项目无法删除" };
}

@end
