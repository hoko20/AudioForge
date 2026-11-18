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

`Core/Metadata/XCTAppMetadata.h/.m` 以上游 `WQUI.m` 的 `wq_app_icon` 为基线（私有 UIKit 图标接口 + 占位指纹过滤、安装包 `Info.plist` / PNG 读取、父 bundle id 回退、中性占位 tile），并额外接入 LaunchServices / IconServices 图标缓存与 **CoreUI (`CUICatalog`) 对 `.app/Assets.car` 的按名解析** —— 上游注释已说明 iOS 26 会拒绝第三方进程的 UIKit 图标请求，这是在该系统上取到真实图标所必需的补充；所有私有 API 均运行时动态解析，不链接私有 framework。该文件只用于按需读取应用图标，不参与容器枚举主链路；原始版权与许可证声明保留在文件头。`Core/Sandbox/XCTContainerBridge.h/.m` 是本工程的集成层：注册全局回调、应用发现、目录列表、排序所需的 `mtime`/扩展名、自检、图标探测与缓存修复。

上游其它文件（`WQApps.m`、`WQCache.m`、`WQHealth.m`、`WQUI.m`、编辑器、SQLite、ZIP、UI 等）**未包含**。

## 沙盒技术：worse_query

感谢 **Taj C (forcequit)**，仓库：https://github.com/forcequitOS/worse_query ，GPL-3.0-or-later。通过 `WQAccess.m` 中的 `container_query_*` / `sandbox_extension_consume` 动态解析接入，未捆绑整个 worse_query 仓库。

## 容器枚举：KAMUI / fsgetpath

感谢 **murk-sus**，仓库：https://github.com/murk-sus/kamui-escape 。上游标注的 `fsgetpath` 文件 ID 枚举思路由 `WQAccess.m` 沿用，未导入 KAMUI 源码。

## 系统依赖

Foundation / UIKit / Security / ImageIO / libSystem（XPC、clonefile、xattr）/ zlib 由 Apple SDK 与系统库提供，仓库不捆绑 SDK 或二进制 framework。XcodeGen 与 Swift 工具链仅为构建工具。

分发二进制时必须同时提供对应源码与构建脚本，并保留上述声明、原始版权头与许可证。上述作者不为本工程背书。
