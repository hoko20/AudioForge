import SwiftUI
import UniformTypeIdentifiers

/// 「应用砸壳」：导入未解密的 IPA → FairPlay 解密 → 导出可重签的 IPA。
struct DecryptView: View {
    @StateObject private var model = DecryptModel()
    @State private var shareItem: ShareItem?
    @State private var showLogs = false
    @State private var showPicker = false
    @State private var showBoundaries = false

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        List {
            Section {
                heroCard.cardRow(top: 8, bottom: 4)
            }

            if let errorText = model.errorText {
                Section {
                    InlineNotice(text: errorText, tone: Palette.danger).cardRow(top: 2, bottom: 2)
                }
            }
            if let notice = model.notice {
                Section {
                    InlineNotice(text: notice, tone: Palette.secondary).cardRow(top: 2, bottom: 2)
                }
            }

            Section {
                if model.outputs.isEmpty {
                    emptyOutputs.cardRow(top: 2, bottom: 4)
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.outputs) { item in
                            outputRow(item)
                        }
                    }
                    .cardRow(top: 2, bottom: 4)
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: "已解密 IPA")
                    Spacer()
                    Text(model.outputs.isEmpty ? "暂无产物" : "\(model.outputs.count) 个 · 可分享或删除")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiary)
                }
                .textCase(nil)
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }

            Section {
                boundaryCard.cardRow(top: 2, bottom: 6)
            }

            Section {
                Color.clear
                    .frame(height: 78)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .background(Palette.background)
        .refreshable { model.loadOutputs() }
        .enableInteractivePop()
        .glassNavigationBar(title: "应用砸壳")
        .onAppear { model.loadOutputs() }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(isPresented: $showPicker) {
            IPAPicker { url in
                showPicker = false
                if let url { model.start(ipaURL: url) }
            }
        }
    }

    // MARK: - 顶部卡片

    private var heroCard: some View {
        CardBox(radius: 22, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Palette.placeholder)
                        Image(systemName: "lock.open.display")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.currentName ?? "导入未解密的 IPA")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
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
                    VStack(alignment: .leading, spacing: 8) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Palette.placeholder)
                                Capsule()
                                    .fill(Palette.ink)
                                    .frame(width: max(proxy.size.width * model.progress, 6))
                            }
                        }
                        .frame(height: 5)

                        HStack(spacing: 10) {
                            Text("\(Int(model.progress * 100))%")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Palette.secondary)
                            Spacer()
                            Button {
                                model.cancel()
                            } label: {
                                Text("取消")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.danger)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Palette.placeholder, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        Button {
                            showPicker = true
                        } label: {
                            Label("导入 IPA", systemImage: "square.and.arrow.down")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(Palette.ink, in: Capsule())
                        }
                        .buttonStyle(.plain)

                        if let result = model.lastResult {
                            Button {
                                shareItem = ShareItem(url: result.url)
                            } label: {
                                Label("分享", systemImage: "square.and.arrow.up")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Palette.ink)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(Palette.placeholder, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                        if let result = model.lastResult {
                            Text(result.sizeText)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Palette.tertiary)
                        }
                    }

                    Text("选择一个未解密的 .ipa 文件，解密后导出到「已解密 IPA」。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiary)
                }

                if !model.logs.isEmpty {
                    Divider().overlay(Palette.separator)
                    DisclosureGroup(isExpanded: $showLogs) {
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(Palette.secondary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.top, 8)
                        }
                        .frame(height: 168)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "terminal")
                                .font(.system(size: 12, weight: .medium))
                            Text("运行日志 · \(model.logs.count) 行")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Palette.ink)
                    }
                    .tint(Palette.secondary)
                }
            }
        }
    }

    // MARK: - 空状态

    private var emptyOutputs: some View {
        CardBox(radius: 18, padding: 16) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Palette.tertiary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("还没有解密产物")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text("导入 IPA 完成后会出现在这里，可分享或删除。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - 说明与边界

    private var boundaryCard: some View {
        CardBox(radius: 18, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showBoundaries.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13, weight: .medium))
                        Text("说明与边界")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Image(systemName: showBoundaries ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.tertiary)
                    }
                    .foregroundStyle(Palette.ink)
                }
                .buttonStyle(.plain)

                if showBoundaries {
                    VStack(alignment: .leading, spacing: 9) {
                        boundaryRow("checkmark.shield", "只解本机已有 FairPlay 授权（`SC_Info`）的 IPA；跨账号或缺少 SINF 的包会跳过。")
                        boundaryRow("exclamationmark.triangle", "系统 App、无加密的可执行文件不处理；已砸壳的包会直接透传。")
                        boundaryRow("externaldrive", "解包暂存在 App Group，需约两倍解压空间，结束自动清理。")
                        boundaryRow("signature", "产物已移除 `_CodeSignature`，未签名，安装前需自行重签。")
                        boundaryRow("wifi.slash", "全程离线：不上传文件、不读取 Apple 账号信息。")
                    }
                    .padding(.top, 2)
                } else {
                    Text("仅支持本机授权的未解密 IPA；产物未签名，需要重签。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiary)
                }
            }
        }
    }

    private func boundaryRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .frame(width: 16)
            Text(LocalizedStringKey(text))
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 产物行

    private func outputRow(_ item: DecryptModel.OutputIPA) -> some View {
        CardBox(radius: 16, padding: 12) {
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
                        .truncationMode(.middle)
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
                Button {
                    model.delete(item)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.danger)
                        .frame(width: 32, height: 32)
                        .background(Palette.placeholder, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                model.delete(item)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

// MARK: - IPA 文件选择

private struct IPAPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        var types: [UTType] = [.zip]
        if let ipa = UTType(filenameExtension: "ipa") {
            types.insert(ipa, at: 0)
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: IPAPicker

        init(_ parent: IPAPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onPick(nil)
        }
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
