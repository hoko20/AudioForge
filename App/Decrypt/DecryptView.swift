import SwiftUI

/// 「应用砸壳」：选择本机已安装应用 → FairPlay 解密 → 导出 IPA。
/// 只对本机已有授权的应用有效，不联网、不接触 Apple 账号。
struct DecryptView: View {
    @StateObject private var model = DecryptModel()
    @State private var query = ""
    @State private var shareItem: ShareItem?
    @State private var showLogs = false

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    private var filteredApps: [DecryptAppRef] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return model.apps }
        return model.apps.filter {
            $0.name.localizedCaseInsensitiveContains(text) ||
            $0.id.localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        List {
            Section {
                statusCard.cardRow()
            }

            Section {
                SearchCapsule(text: $query, prompt: "搜索应用名称或 Bundle ID")
                    .cardRow()
            }

            if let errorText = model.errorText {
                Section {
                    InlineNotice(text: errorText, tone: Palette.danger).cardRow()
                }
            }
            if let notice = model.notice {
                Section {
                    InlineNotice(text: notice, tone: Palette.secondary).cardRow()
                }
            }

            Section {
                if model.loading && model.apps.isEmpty {
                    loadingRow
                } else if filteredApps.isEmpty {
                    emptyAppsRow
                } else {
                    ForEach(filteredApps) { app in
                        appRow(app)
                    }
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: "已安装应用")
                    Spacer()
                    Text(model.running ? "砸壳进行中" : "点按开始砸壳")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiary)
                }
                .textCase(nil)
                .padding(.horizontal, 20)
                .padding(.top, 6)
            }

            Section {
                if model.outputs.isEmpty {
                    Text("还没有解密产物。完成后会出现在这里，可分享或删除。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiary)
                        .cardRow(top: 4, bottom: 12)
                } else {
                    ForEach(model.outputs) { item in
                        outputRow(item)
                    }
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: "已解密 IPA")
                    Spacer()
                    Text("共 \(model.outputs.count) 个 · 右滑删除")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiary)
                }
                .textCase(nil)
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            Section {
                Text("原理：把 .app 复制到 App Group，逐个 Mach-O 通过 mremap_encrypted 交给 fairplayd 解密，去掉 _CodeSignature 后重新打包。只对本机已安装、已有 FairPlay 授权的应用有效；系统应用通常无法解密。产物需自行重签后安装。")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
                    .cardRow(top: 10, bottom: 16)
            }

            Section {
                Color.clear
                    .frame(height: 70)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .background(Palette.background)
        .refreshable {
            model.loadApps()
            model.loadOutputs()
        }
        .enableInteractivePop()
        .glassNavigationBar(title: "应用砸壳")
        .onAppear { model.loadAppsIfNeeded() }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    // MARK: - 状态卡

    @ViewBuilder
    private var statusCard: some View {
        CardBox(radius: 20, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Palette.placeholder)
                        Image(systemName: "lock.open.display")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                    }
                    .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.currentApp?.name ?? "应用砸壳")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(model.status)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if !model.elapsedText.isEmpty {
                        Text(model.elapsedText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Palette.tertiary)
                    }
                }

                if model.running {
                    ProgressView(value: model.progress)
                        .tint(Palette.ink)
                    HStack(spacing: 10) {
                        Button {
                            model.cancel()
                        } label: {
                            Text("取消")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.danger)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Palette.placeholder, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Text("\(Int(model.progress * 100))%")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Palette.secondary)
                    }
                } else if let result = model.lastResult {
                    HStack(spacing: 10) {
                        Button {
                            shareItem = ShareItem(url: result.url)
                        } label: {
                            Label("分享 IPA", systemImage: "square.and.arrow.up")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.ink)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Palette.placeholder, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Text("\(result.sizeText) · \(result.dateText)")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.tertiary)
                    }
                } else {
                    Text("选择一个已安装应用，解密主程序、框架与扩展并导出 IPA。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                }

                if !model.logs.isEmpty {
                    DisclosureGroup(isExpanded: $showLogs) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(Palette.secondary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.top, 6)
                        }
                        .frame(height: 170)
                    } label: {
                        Text("运行日志 · \(model.logs.count) 行")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.ink)
                    }
                    .tint(Palette.secondary)
                }
            }
        }
    }

    // MARK: - 应用行

    @ViewBuilder
    private func appRow(_ app: DecryptAppRef) -> some View {
        Button {
            model.start(app)
        } label: {
            HStack(spacing: 12) {
                AppIconView(bundleID: app.id, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(app.id)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: model.running ? "hourglass" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canStart)
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        .listRowBackground(Palette.card)
        .listRowSeparator(SwiftUI.Visibility.visible)
    }

    // MARK: - 输出行

    @ViewBuilder
    private func outputRow(_ item: DecryptModel.OutputIPA) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Palette.placeholder)
                Image(systemName: "shippingbox")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text("\(item.sizeText) · \(item.dateText)")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 6)
            Button {
                shareItem = ShareItem(url: item.url)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 32, height: 32)
                    .background(Palette.placeholder, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        .listRowBackground(Palette.card)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                model.delete(item)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Palette.ink)
            Text("正在读取应用列表…")
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        .listRowBackground(Palette.card)
    }

    private var emptyAppsRow: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Palette.tertiary)
            Text(query.isEmpty ? "没有可访问的应用，请先在「文件」页刷新容器列表。" : "没有匹配的应用")
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 16)
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        .listRowBackground(Palette.card)
    }
}

// MARK: - 行样式

private extension View {
    func cardRow(top: CGFloat = 6, bottom: CGFloat = 6) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 20, bottom: bottom, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
