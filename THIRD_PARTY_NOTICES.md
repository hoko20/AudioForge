# 第三方源码、技术与致谢

本工程 GPL-3.0-or-later，完整许可见根目录 `LICENSE` 与 `Vendor/WQFiles/LICENSE`。以下只列出**实际参与本工程构建**的源码与技术来源。

## 实际包含：WQ Files 0.9.5

感谢 **kolbicz**，仓库：https://github.com/kolbicz/WQFiles 。使用 `main` 分支 0.9.5（提交 `9132917`，2026-11-12），GPL-3.0-or-later。

`Vendor/WQFiles/` 内以下文件与上游逐字一致，保留原始版权头：

- `WQAccess.h` / `WQAccess.m` — worse_query 沙盒扩展签发、逐级授权、容器枚举、文件读写、`wq_reset_access_cache`。
- `WQAccessSafety.h` — App Group `Library/Caches` 交换与恢复、路径安全原语。
- `WQLaunchServices.h` / `WQLaunchServices.m` — LaunchServices CSStore 解析、应用显示名与容器标签映射。
- `WQCore.h` / `WQCore.m` — 底层辅助。
- `WQLocalization.h` / `WQLocalization.m` — 上游本地化包装。
- `LICENSE` — 上游许可证原文。

`App/AppAccess/XCTAppMetadata.h/.m` 以上游 `WQUI.m` 的 `wq_app_icon` 为基线（私有 UIKit 图标接口 + 占位指纹过滤、父 bundle id 回退、中性占位 tile），并保留 LaunchServices / IconServices 图标缓存通道。iOS 26 不向第三方进程提供其他 App 的图标，也不提供可读的安装包路径，因此已移除安装包 `Assets.car` / PNG 解析；所有私有 API 均运行时动态解析，不链接私有 framework。该文件只用于按需读取应用图标，不参与容器枚举主链路；原始版权与许可证声明保留在文件头。`App/Sandbox/XCTContainerBridge.h/.m` 是本工程的集成层：注册全局回调、应用发现、目录列表、排序所需的 `mtime`/扩展名、自检与缓存修复。

上游其它文件（`WQApps.m`、`WQCache.m`、`WQHealth.m`、`WQUI.m`、编辑器、SQLite、ZIP、UI 等）**未包含**。

## 本机 FairPlay 解密：iPadn

`App/Decrypt/FairPlayCore.h` / `FairPlayCore.c` 移植自 **mengangs/ipadn**（https://github.com/mengangs/ipadn ，GPL-2.0-or-later，2.2.0，2026-11-17），用于对本机已授权的 App Store 应用执行 SINF 解密。机制为 `mmap(PROT_READ)` + `mremap_encrypted(cryptid 2)`，由 `fairplayd` 按 `<二进制目录>/SC_Info/<名称>.sinf` 解析许可；上游文件头注明该机制亦参考 morzelowski/FairPlayed 的公开描述。

`App/Decrypt/DecryptService.swift`、`DecryptModel.swift`、`DecryptView.swift`、`ZipWriter.swift` 是本工程的集成层：把已安装 `.app` 暂存到 App Group、补齐 `SC_Info`、逐文件解密、去签名并打包 IPA。原文件版权说明保留在 `FairPlayCore.c` 头部；本工程整体按 GPL-3.0-or-later 分发，与 GPL-2.0-or-later 的源码兼容。

## 沙盒技术：worse_query

感谢 **Taj C (forcequit)**，仓库：https://github.com/forcequitOS/worse_query ，GPL-3.0-or-later。通过 `WQAccess.m` 中的 `container_query_*` / `sandbox_extension_consume` 动态解析接入，未捆绑整个 worse_query 仓库。

## 容器枚举：KAMUI / fsgetpath

感谢 **murk-sus**，仓库：https://github.com/murk-sus/kamui-escape 。上游标注的 `fsgetpath` 文件 ID 枚举思路由 `WQAccess.m` 沿用，未导入 KAMUI 源码。

## 系统依赖

Foundation / UIKit / Security / ImageIO / libSystem（XPC、clonefile、xattr）/ zlib 由 Apple SDK 与系统库提供，仓库不捆绑 SDK 或二进制 framework。XcodeGen 与 Swift 工具链仅为构建工具。

分发二进制时必须同时提供对应源码与构建脚本，并保留上述声明、原始版权头与许可证。上述作者不为本工程背书。
