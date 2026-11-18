// 缓存清理适配层：基于 WQ Files 0.9.16 的 wq_measure_tree / wq_purge_contents。
// 只处理每个 App 容器里公认可删的目录，目录本身保留。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XCTCacheOps : NSObject

/// 一个容器里实际存在的可清理项目（Library/Caches、tmp、Library/Logs）。
/// 每条记录：kind、title、path。
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)cacheTargetsForContainer:(NSString *)containerPath
    NS_SWIFT_NAME(cacheTargets(containerPath:));

/// 递归字节数；目录不存在时为 0。
+ (NSNumber *)measureTree:(NSString *)path NS_SWIFT_NAME(measureTree(_:));

/// 清空目录内容（目录本身保留），返回 @{@"freed": NSNumber} 或 @{@"error": NSString}。
+ (NSDictionary<NSString *, id> *)purgeContentsOf:(NSString *)path
    NS_SWIFT_NAME(purgeContents(of:));

@end

NS_ASSUME_NONNULL_END
