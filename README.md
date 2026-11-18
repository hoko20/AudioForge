# WQtool

只保留「获取应用容器 + 沙盒访问」的最小 iOS 应用，底层直接采用 **kolbicz/WQFiles 0.9.5** 的实现（worse_query，无需越狱）。界面是浅灰白底 + 白色圆角卡片 + 悬浮胶囊 tab 栏的 SwiftUI 壳，不使用系统蓝色强调色。

## 目录结构

```
App/                   全部源码，一个目录 = 一个功能，功能相关文件（界面 + 逻辑）都放同一目录
├── BridgingHeader.h   暴露给 Swift 的 ObjC 头文件总入口
├── Entry/             应用入口
│   ├── SandboxApp.swift        @main，窗口、全局容器状态
│   └── ContentView.swift       悬浮胶囊 Tab 栏
├── Tabs/              三个一级页面
│   ├── FilesTab.swift          文件：应用容器列表
│   ├── ToolsTab.swift          工具：收藏夹 + 工具入口
│   └── SettingsTab.swift       设置：运行环境 / 数据 / 关于
├── Browser/           目录浏览
│   ├── FileView.swift                  根目录浏览
│   ├── DirectoryView.swift             任意目录浏览（排序 / 收藏 / 手势）
│   └── DirectoryPickerSheet.swift      目录选择器
├── AppAccess/         应用沙盒访问与图标
│   ├── AppAccessView.swift             容器授权与自检界面
│   ├── AppIconView.swift               真实图标加载与缓存
│   └── XCTAppMetadata.h/.m             应用名、图标、分类元数据
├── Sandbox/           沙盒底层桥接
│   ├── XCTContainerBridge.h/.m         容器发现、token 授权、日志
│   └── XCTFileOps.h/.m                 跨沙盒读写、目录列举
├── Replace/           替换文件工具
│   ├── ReplaceFileView.swift           界面
│   └── ReplaceFileModel.swift          状态与校验
├── Convert/           音频转换与试听
│   ├── AudioConvertView.swift          mp3/mp4 → aud / amr / m4a
│   ├── AudioPlayerSheet.swift          转换产物试听
│   ├── AudioConverter.h/.m             解码 → AMR / SILK / AAC 编码
│   └── AudioPlayback.h/.m              SILK / AMR 解码后交给系统播放
├── Cache/             缓存清理
│   ├── CacheCleanView.swift            缓存统计与清理界面
│   └── XCTCacheOps.h/.m                缓存目录统计与清理
├── Decrypt/           应用砸壳（FairPlay 解密）
│   ├── DecryptView.swift               导入 IPA、进度、日志与导出
│   ├── DecryptModel.swift              任务状态与产物列表
│   ├── DecryptService.swift            解包、扫描、解密、去签名、打包
│   ├── ZipReader.swift                 zlib inflate 的 ZIP 解包
│   ├── ZipWriter.swift                 zlib deflate 的 ZIP 写入
│   └── FairPlayCore.h/.c               mremap_encrypted + fairplayd 解密核心
└── Shared/            全局共用
    ├── Theme.swift                     配色、卡片、按钮样式
    ├── Models.swift                    数据模型与持久化
    └── NavigationEnhancements.swift    右滑返回与导航修复

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
| **工具** | **收藏夹**（添加 / 重命名 / 排序 / 删除 / 复制路径 / 直接跳转）、快速跳转、**应用砸壳**（FairPlay 解密已安装 App 并导出 IPA）、**音频转换**（mp3/mp4 → amr / aud / m4a）、**缓存清理** |
| **设置** | 运行环境（含授权自检、刷新与日志入口）、收藏路径管理、文件排序默认值、完整 inode 扫描、重置访问缓存、重新查找 LaunchServices、清空收藏、签名说明 |

收藏夹用 `UserDefaults` 持久化，只保存名称与路径，不复制任何目录内容。浏览到深层目录时点星标，之后在「工具」里一键直达。

### 应用图标（iOS 26）

iOS 26 不再向第三方进程提供其他 App 的图标，只能拿到固定占位图；也没有可读的 `.app` 路径去解析 `Assets.car`。因此图标解析只保留两条系统通道：

| 通道 | 来源 | 说明 |
|---|---|---|
| A | UIKit 私有接口 | 遍历 `_applicationIconImageForBundleIdentifier:format:scale:` 的 format，做占位图判定 |
| B | LaunchServices / IconServices | `LSApplicationProxy` 的 `iconDataForVariant:`、`ISIconCache` 缓存位图 |

两条都拿不到时统一画中性色块占位（`XCTServiceTile`），不再尝试读安装包。系统应用的图标仍由 A/B 正常返回。

### 文件排序

目录页右上角的下拉菜单支持 **名称 / 大小 / 修改时间 / 类型** 四种依据，旁边的按钮切换升降序，菜单内可切换「文件夹优先」。设置会持久化，所有目录页共用，也能在「设置」里改默认值。排序完全在 Swift 侧完成（`SortPreferences`），切换排序不会重新申请沙盒扩展；`listDirectory:` 额外返回 `mtime` 与扩展名。名称始终是确定性的平局判定，文件夹优先时文件夹恒定在顶部、升降序只作用于组内。

### 导航与手势

- **左边缘右滑返回**：隐藏系统返回按钮会让 SwiftUI 禁用 `interactivePopGestureRecognizer`。`App/Shared/NavigationEnhancements.swift` 用一个零尺寸的 `UIViewControllerRepresentable` 重新挂上 delegate（仅在 `viewControllers.count > 1` 时允许开始，避免根页面半弹出卡死），并在每次导航更新后校验 delegate 未被 SwiftUI 重置。
- **毛玻璃导航栏**：三个 tab 与目录页统一用 `.ultraThinMaterial` 工具栏背景 + inline 标题，标题显示当前 tab 名称（文件 / 工具 / 设置）或当前目录名。内容从下方滚过时会透出模糊效果。

### 目录导航边界

`PathRoute` 携带 `root`（已知取得沙盒扩展的最深路径）。「上级目录」是 **pop**（返回栈里已有的页面），不是 push；仅当父目录仍在 `root` 内才显示。容器根页面与从收藏夹直接打开的页面不会显示上溯入口，因此不会跳到 `/…/Containers/Data/Application` 这类无授权目录，也不会出现无限上溯报错的页面链。只有 `kind == "dir"` 的条目可进入下一级。

## 应用砸壳（FairPlay 解密）

工具 → **应用砸壳** → **导入 IPA**：选择一个未解密的原始 IPA，解包到 App Group 暂存区，逐个 Mach-O 解密，去掉 `_CodeSignature` 后重新打包成 IPA（`Documents/Decrypted`）。

- 核心 `FairPlayCore.c` 移植自 [mengangs/ipadn](https://github.com/mengangs/ipadn)（GPL-2.0-or-later）：`mmap(PROT_READ)` + `mremap_encrypted(cryptid 2)`，由 `fairplayd` 按 `<二进制目录>/SC_Info/<名称>.sinf` 取授权，逐页读回明文并做熵值与 ARM64 指令校验。
- 只处理带 FairPlay 授权的未解密 IPA；已解密的包会直接跳过，系统应用无法解密。
- 暂存目录必须是 App Group（`fairplayd` 拒绝 data container），因此签名必须带 App Group 权限。
- 导出的是未签名 IPA，需要自行重签（AltStore / SideStore / 证书）后才能安装。
- ZIP 解包/打包都是工程内的最小实现（zlib inflate/deflate），不引入第三方依赖。

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
