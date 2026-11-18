import SwiftUI
import UniformTypeIdentifiers

/// 「应用砸壳」：导入未解密的 IPA → FairPlay 解密 → 导出 IPA。
/// 只对本机已有授权的应用有效，不联网、不接触 Apple 账号。
struct DecryptView: View {
    @StateObject private var model = DecryptModel()
    @State private var shareItem: ShareItem?
    @State private var showLogs = false
    @State private var showPicker = false

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        List {
            Section {
                statusCard.cardRow()
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
                if model.outputs.isEmpty {
                    Text("还没有解密产物。导入 IPA 完成后会出现在这里，可分享或删除。")
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
                Text("流程：把导入的 IPA 解包到 App Group → 逐个 Mach-O 通过 mremap_encrypted 交给 fairplayd 解密 → 去掉 _CodeSignature → 重新打包。只支持未加密的原始 IPA（含 SC_Info 授权），已砸壳的包会直接跳过；产物未签名，需要自行重签后安装。")
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
                        Text(model.currentName ?? "应用砸壳")
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
                } else {
                    HStack(spacing: 10) {
                        Button {
                            showPicker = true
                        } label: {
                            Label("导入 IPA", systemImage: "square.and.arrow.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.ink)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Palette.placeholder, in: Capsule())
                        }
                        .buttonStyle(.plain)

                        if let result = model.lastResult {
                            Button {
                                shareItem = ShareItem(url: result.url)
                            } label: {
                                Label("分享", systemImage: "square.and.arrow.up")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.ink)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Palette.placeholder, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        if let result = model.lastResult {
                            Text("\(result.sizeText) · \(result.dateText)")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.tertiary)
                        }
                    }
                    Text("选择未解密的 IPA 文件开始。支持 iPhone / iPad 应用包。")
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
