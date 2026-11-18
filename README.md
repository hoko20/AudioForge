# WQtool

只保留「获取应用容器 + 沙盒访问」的最小 iOS 应用，底层直接采用 **kolbicz/WQFiles 0.9.5** 的实现（worse_query，无需越狱）。界面是浅灰白底 + 白色圆角卡片 + 悬浮胶囊 tab 栏的 SwiftUI 壳，不使用系统蓝色强调色。

## 目录结构

```
App/                    SwiftUI 界面层（纯 UI 与状态，不含系统私有调用）
├── Entry/              应用入口
│   ├── SandboxApp.swift        @main，窗口、全局容器状态
│   └── ContentView.swift       悬浮胶囊 Tab 栏
├── Tabs/               三个一级页面
│   ├── FilesTab.swift          文件：应用容器列表
│   ├── ToolsTab.swift          工具：收藏夹 + 工具入口
│   └── SettingsTab.swift       设置：运行环境 / 数据 / 关于
├── Features/           按功能划分的二级页面
│   ├── Browser/                目录浏览
│   │   ├── FileView.swift              根目录浏览
│   │   ├── DirectoryView.swift         任意目录浏览（排序 / 收藏 / 手势）
│   │   └── DirectoryPickerSheet.swift  目录选择器
│   ├── AppAccess/              应用沙盒访问
│   │   ├── AppAccessView.swift         容器授权与自检界面
│   │   └── AppIconView.swift           真实图标加载与缓存
│   ├── Replace/                替换文件工具
│   │   ├── ReplaceFileView.swift       界面
│   │   └── ReplaceFileModel.swift      状态与校验
│   ├── Convert/                音频转换
│   │   ├── AudioConvertView.swift      mp3/mp4 → aud / amr / m4a
│   │   └── AudioPlayerSheet.swift      转换产物试听
│   └── Cache/                  缓存清理
│       └── CacheCleanView.swift        缓存统计与清理
└── Core/               界面共用基础
    ├── Theme.swift                     配色、卡片、按钮样式
    ├── Models.swift                    数据模型与持久化
    └── NavigationEnhancements.swift    右滑返回与导航修复

Core/                   ObjC 桥接层（系统私有接口都在这里）
├── BridgingHeader.h    暴露给 Swift 的头文件总入口
├── Sandbox/            沙盒访问
│   ├── XCTContainerBridge.h/.m   容器发现、token 授权、日志
│   └── XCTFileOps.h/.m           跨沙盒读写、目录列举
├── Metadata/           应用元数据
│   └── XCTAppMetadata.h/.m       真实名称、图标、分类
├── Cache/              缓存
│   └── XCTCacheOps.h/.m          缓存目录统计与清理
└── Audio/              音频编解码
    ├── AudioConverter.h/.m       解码 → AMR / SILK / AAC 编码
    └── AudioPlayback.h/.m        SILK / AMR 解码后交给系统播放

Vendor/                 第三方源码（不要改）
└── WQFiles/            上游 kolbicz/WQFiles 0.9.5 源码，编译进 App 必需
                        （Vendor/include、Vendor/lib 由 Scripts/build-audio-codecs.sh 在 CI 生成，不入库）

Scripts/                构建脚本
├── build-audio-codecs.sh      编译 SILK / AMR 静态库
├── build-ipa.sh               CI 主构建（xcodegen + xcodebuild + 打包）
├── build-ipa.ps1              Windows 本地构建
└── verify-ipa.py              产物校验
Resources/              Info.plist、AppGroup.entitlements、图标资源
.github/workflows/      GitHub Actions 工作流
```

## 界面

| Tab | 内容 |
|---|---|
| **文件** | 应用容器列表（搜索、分类筛选、刷新、停止扫描）→ 逐级目录浏览；任意目录右上角星标可一键收藏 |
| **工具** | **收藏夹**（添加 / 重命名 / 排序 / 删除 / 复制路径 / 直接跳转）、快速跳转、**音频转换**（mp3/mp4 → amr / aud / m4a）、**缓存清理** |
| **设置** | 运行环境（含授权自检、刷新与日志入口）、收藏路径管理、文件排序默认值、完整 inode 扫描、重置访问缓存、重新查找 LaunchServices、清空收藏、签名说明 |

收藏夹用 `UserDefaults` 持久化，只保存名称与路径，不复制任何目录内容。浏览到深层目录时点星标，之后在「工具」里一键直达。

### 应用图标（iOS 26 真实图标）

上游 `WQUI.m` 的注释直接点明根因：**iOS 26 拒绝第三方进程的 UIKit 图标请求**，私有 `_applicationIconImageForBundleIdentifier:format:scale:` 只返回固定占位图；上游兜底只找 `.app` 里散落的 PNG，而现代应用的图标都编译进 `Assets.car`，所以两者都失败、列表全是灰色 tile。

`Core/Metadata/XCTAppMetadata.m` 在上游链路之外补了四层，逐层回退：

| 层 | 来源 | 说明 |
|---|---|---|
| A | UIKit 私有接口 | 遍历 format 0..8；用 Safari / 设置 / 相机 / 不存在的 id 四个探针判定「该 format 是否恒返回同一张占位图」，恒定的直接丢弃 |
| B | LaunchServices / IconServices | `LSApplicationProxy` 的 `iconDataForVariant:`、`ISIconCache` 的缓存位图 |
| C | **Assets.car** | `dlopen` CoreUI → `CUICatalog` 打开 `.app/Assets.car` → 按 `CFBundleIconName` 及 catalog 内 `AppIcon*` 名字取 `CUINamedImage` 的 `CGImageRef` |
| D | 安装包 PNG | 除固定名字外再枚举 `.app` 目录下所有含 icon 的 PNG |
| E | 父 bundle id / 中性 tile | 扩展回退到主应用，最后才是灰底符号 |

所有私有调用都经过 `respondsToSelector` + `NSInvocation` + `@try/@catch`，候选位图要做尺寸与颜色方差校验，占位图不会被当成真实图标。真实图标落磁盘缓存（只缓存真实图标，不缓存 tile），Swift 侧用串行后台队列 + `NSCache` 按需加载，避免图标授权挤占容器 token。设置里可关闭 Assets.car 解析；「工具 → 重新解析前 12 个应用图标」会绕过缓存逐层探测并在界面上直接列出每个应用的命中来源，原始日志里有 A/B/C 三层的失败原因。

### 文件排序

目录页右上角的下拉菜单支持 **名称 / 大小 / 修改时间 / 类型** 四种依据，旁边的按钮切换升降序，菜单内可切换「文件夹优先」。设置会持久化，所有目录页共用，也能在「设置」里改默认值。排序完全在 Swift 侧完成（`SortPreferences`），切换排序不会重新申请沙盒扩展；`listDirectory:` 额外返回 `mtime` 与扩展名。名称始终是确定性的平局判定，文件夹优先时文件夹恒定在顶部、升降序只作用于组内。

### 导航与手势

- **左边缘右滑返回**：隐藏系统返回按钮会让 SwiftUI 禁用 `interactivePopGestureRecognizer`。`App/Core/NavigationEnhancements.swift` 用一个零尺寸的 `UIViewControllerRepresentable` 重新挂上 delegate（仅在 `viewControllers.count > 1` 时允许开始，避免根页面半弹出卡死），并在每次导航更新后校验 delegate 未被 SwiftUI 重置。
- **毛玻璃导航栏**：三个 tab 与目录页统一用 `.ultraThinMaterial` 工具栏背景 + inline 标题，标题显示当前 tab 名称（文件 / 工具 / 设置）或当前目录名。内容从下方滚过时会透出模糊效果。

### 目录导航边界

`PathRoute` 携带 `root`（已知取得沙盒扩展的最深路径）。「上级目录」是 **pop**（返回栈里已有的页面），不是 push；仅当父目录仍在 `root` 内才显示。容器根页面与从收藏夹直接打开的页面不会显示上溯入口，因此不会跳到 `/…/Containers/Data/Application` 这类无授权目录，也不会出现无限上溯报错的页面链。只有 `kind == "dir"` 的条目可进入下一级。

## 与上游 WQ Files 的关系

- `Vendor/WQFiles/` 与上游 0.9.5 逐字一致：`WQAccess` / `WQAccessSafety` / `WQLaunchServices` / `WQCore` / `WQLocalization`。包含 iOS 26 的 alternative query flags、CSStore 新布局、`wq_reset_access_cache` 缓存修复等上游修复。
- 上游在 `main()` 里注册三个全局回调（`wq_set_container_label_resolver` / `wq_set_container_list_provider` / `wq_set_full_scan_ui`）；SwiftUI 没有显式 `main()`，这里用 `__attribute__((constructor))` 在镜像加载时完成等价注册。
- 枚举顺序对齐上游 `WQApps.m`：先 `wq_enumerate`，再 `wq_load_display_names`。
- 完整扫描确认默认允许。iOS 26 上应用列表来自 LaunchServices 数据库，数据库不可读时需要 `fsgetpath` 全卷扫描，拒绝该扫描会得到空列表；设置里可关闭，扫描中可点「停止」。
- 最低系统版本 `iOS 26.0`（`MinimumOSVersion` 与部署目标），系统支持判定直接读 `NSProcessInfo`，不依赖编译 SDK 的 `@available`。

## 运行前提

1. **iOS 26 或 27** 真机，模拟器不支持。
2. **签名必须携带 App Group** `group.local.xchat.transfer`。运行时用 `SecTaskCopyValueForEntitlement` 读取实际收到的 group；显示「未提供」即重签工具丢了 entitlement，容器访问完全失效。
   - 可用：AltStore / SideStore / Impactor（会自动创建 App Group），或 explicit App ID + 启用 App Groups 能力 + 对应描述文件。
   - 常见失败：Sideloadly、通配符 App ID `*` 的描述文件，通常不含 App Group。
3. 使用非公开 API（`dlsym` 解析 `libsystem_containermanager.dylib`），系统小版本变动可能导致失效。

## 排障顺序

设置 → **重置访问缓存** → **重新查找 LaunchServices 数据库** → **刷新应用容器列表**。仍为空则看「工具 → 授权自检」与原始日志中的 `grant` / `enumerate` / `NO TOKEN` 行。

## 构建

GitHub Actions `Build WQtool IPA`：推送 `main` 或手动触发。工作流在 `macos-26` 镜像上挑带 iOS 26+ SDK 的 Xcode，XcodeGen 生成工程，`xcodebuild` 编译、adhoc 签名、打包 IPA、上传 `WQtool-IPA` artifact（含 IPA、SHA-256、`verify.json`、`entitlements.plist`）。

本地 macOS：

```sh
brew install xcodegen
xcodegen generate --spec project.yml
bash Scripts/build-ipa.sh
```

产物是 **adhoc 签名的重签输入**，无 `embedded.mobileprovision`，不能普通真机安装。

Windows 一键构建：双击 `build-ipa.bat`，脚本会创建/复用 GitHub 仓库、推送源码、触发工作流、等待完成后把 IPA 下载到 `dist\WQtool-adhoc.ipa`。首次运行会提示输入 PAT（需要 `repo` + `workflow` 权限）。

## 许可证

GPL-3.0-or-later，见 [LICENSE](LICENSE)。第三方源码、技术来源与致谢见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。分发二进制必须同时提供源码与构建脚本。

已在 iOS 26.5.2 真机上验证应用容器列表与目录访问正常；每个 iOS 小版本的容器授权仍需各自确认。
