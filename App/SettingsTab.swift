import SwiftUI

struct SettingsTab: View {
    @EnvironmentObject private var settings: AccessSettings
    @EnvironmentObject private var files: FileListModel
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var sort: SortPreferences
    @State private var showLog = false
    @State private var busyAction: String?
    @State private var alertMessage: String?
    @State private var confirmClearBookmarks = false
    @State private var checks: [String: String] = [:]
    @State private var checking = false

    /// 与自检报告顺序一致；App Group / 系统版本 已在上方独立行显示，不重复。
    private let checkOrder = [
        "系统支持", "完整扫描", "上次扫描被拒",
        "容器父目录", "LS 数据库", "LS 记录", "应用名称库",
        "上次枚举", "抽样容器", "可读取", "可识别", "被拒样本"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // MARK: 运行环境
                    HStack(spacing: 10) {
                        SectionLabel(text: "运行环境")
                        Spacer()
                        if checking {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Palette.ink)
                                .frame(width: 34, height: 34)
                                .background(Palette.card, in: Circle())
                        } else {
                            HeaderIcon(system: "arrow.clockwise") {
                                refreshEnvironment()
                            }
                        }
                        HeaderIcon(system: "doc.text") {
                            showLog = true
                        }
                    }

                    CardBox(radius: 20, padding: 0) {
                        VStack(spacing: 0) {
                            InfoRow(title: "App Group", value: files.appGroup)
                            ThinSeparator().padding(.leading, 16)
                            InfoRow(title: "系统版本", value: files.systemVersion)
                            ThinSeparator().padding(.leading, 16)
                            InfoRow(title: "容器访问", value: files.supported ? "支持" : "需要 iOS 26+")
                            ThinSeparator().padding(.leading, 16)
                            InfoRow(title: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "未知")
                            ThinSeparator().padding(.leading, 16)
                            InfoRow(title: "版本", value: appVersion)

                            ForEach(checkOrder, id: \.self) { key in
                                if let value = checks[key] {
                                    ThinSeparator().padding(.leading, 16)
                                    InfoRow(title: key, value: value)
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }

                    Text("App Group 由签名注入。显示「未提供」说明重签工具丢弃了 com.apple.security.application-groups。下方自检项抽样尝试打开其它应用容器，NO TOKEN 多为签名丢失 App Group 或缓存交换状态损坏。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiary)

                    // MARK: 扫描
                    SectionLabel(text: "扫描")
                    CardBox {
                        VStack(alignment: .leading, spacing: 16) {
                            Toggle(isOn: $settings.fullScan) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("允许完整 inode 扫描")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Palette.ink)
                                    Text("iOS 26 上应用列表来自 LaunchServices 数据库；数据库不可读时才回退到 fsgetpath 全卷扫描，可能耗时数分钟。关闭此项会让回退路径直接放弃。")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Palette.secondary)
                                }
                            }
                            .tint(Palette.ink)

                            ThinSeparator()

                            ActionRow(title: "停止当前扫描", system: "stop.circle", busy: busyAction) {
                                XCTContainerBridge.stopFullScan()
                                alertMessage = "已请求停止正在进行的完整扫描。"
                            }
                        }
                    }

                    // MARK: 文件排序
                    SectionLabel(text: "文件排序")
                    CardBox {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("排序依据")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Palette.ink)
                                Spacer(minLength: 8)
                                Picker("排序依据", selection: $sort.key) {
                                    ForEach(SortKey.allCases) { key in
                                        Text(key.title).tag(key)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(Palette.ink)
                            }

                            ThinSeparator()

                            Toggle(isOn: $sort.ascending) {
                                Text("升序（A→Z / 小→大 / 旧→新）")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Palette.ink)
                            }
                            .tint(Palette.ink)

                            ThinSeparator()

                            Toggle(isOn: $sort.foldersFirst) {
                                Text("文件夹始终排在前面")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Palette.ink)
                            }
                            .tint(Palette.ink)

                            Text("当前：\(sort.summary)。目录页右上角也可直接改排序，设置会自动保存。")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.tertiary)
                        }
                    }

                    // MARK: 维护
                    SectionLabel(text: "维护")
                    CardBox(radius: 20, padding: 0) {
                        VStack(spacing: 0) {
                            ActionRow(title: "重置访问缓存", system: "arrow.triangle.2.circlepath", busy: busyAction) {
                                runOffMain("重置访问缓存") {
                                    if let reason = XCTContainerBridge.resetAccessCache() {
                                        return "重置失败：\(reason)"
                                    }
                                    return "已修复 App Group 的 Library/Caches 交换状态。现在回到「文件」页刷新一次。"
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            ThinSeparator().padding(.leading, 16)

                            ActionRow(title: "重新查找 LaunchServices 数据库", system: "magnifyingglass", busy: busyAction) {
                                XCTContainerBridge.forgetLaunchServicesStore()
                                alertMessage = "已忘记记住的数据库位置，下次刷新会重新定位。"
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            ThinSeparator().padding(.leading, 16)

                            ActionRow(title: "刷新应用容器列表", system: "arrow.clockwise", busy: busyAction) {
                                files.refresh()
                                alertMessage = "已开始刷新，请到「文件」页查看结果。"
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }

                    Text("出现 NO TOKEN / 空列表时，按顺序尝试：重置访问缓存 → 重新查找数据库 → 刷新。仍失败再看原始日志。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiary)

                    // MARK: 数据
                    SectionLabel(text: "数据")
                    CardBox {
                        VStack(alignment: .leading, spacing: 14) {
                            InfoRow(title: "收藏路径", value: "\(bookmarks.items.count) 条")
                            ThinSeparator()
                            Button {
                                confirmClearBookmarks = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "trash")
                                    Text("清空收藏夹")
                                }
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(bookmarks.items.isEmpty ? Palette.tertiary : Palette.danger)
                            }
                            .buttonStyle(.plain)
                            .disabled(bookmarks.items.isEmpty)
                        }
                    }

                    // MARK: 关于
                    SectionLabel(text: "关于")
                    CardBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("基于 WQ Files 0.9.5 的 worse_query 沙盒扩展实现，仅保留应用容器发现与目录访问。")
                            Text("要求 iOS 26 / 27，且必须用保留 App Group entitlement 的方式重签（AltStore、SideStore、Impactor，或 explicit App ID + 启用 App Groups 的描述文件）。Sideloadly、通配符描述文件通常会丢失 App Group。")
                            Text("GPL-3.0-or-later。技术来源：worse_query by Taj C (forcequit)；容器枚举 fsgetpath 思路来自 KAMUI。")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                    }

                    Spacer(minLength: 120)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
            .background(Palette.background)
            .enableInteractivePop()
            .glassNavigationBar(title: "设置")
            .onAppear {
                if checks.isEmpty { refreshEnvironment() }
            }
            .sheet(isPresented: $showLog) {
                DiagnosticsView(text: XCTContainerBridge.diagnostics())
            }
            .alert("提示", isPresented: Binding(get: { alertMessage != nil },
                                              set: { if !$0 { alertMessage = nil } })) {
                Button("好", role: .cancel) { }
            } message: {
                Text(alertMessage ?? "")
            }
            .confirmationDialog("清空全部收藏路径？", isPresented: $confirmClearBookmarks, titleVisibility: .visible) {
                Button("清空收藏", role: .destructive) {
                    for item in bookmarks.items { bookmarks.remove(id: item.id) }
                }
                Button("取消", role: .cancel) { }
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "1.0") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }

    /// 重新跑一次授权自检，刷新「运行环境」里的自检项。
    private func refreshEnvironment() {
        guard !checking else { return }
        checking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let report = XCTContainerBridge.runSelfCheck()
            DispatchQueue.main.async {
                self.checks = report
                self.checking = false
            }
        }
    }

    private func runOffMain(_ label: String, work: @escaping () -> String) {
        busyAction = label
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async {
                busyAction = nil
                alertMessage = result
            }
        }
    }
}

// MARK: - Rows

private struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(Palette.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct ActionRow: View {
    let title: String
    let system: String
    let busy: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: system)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 6)
                if busy == title { ProgressView() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy != nil)
    }
}
