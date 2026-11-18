import SwiftUI

/// 缓存清理：扫描每个应用容器的 Library/Caches、tmp、Library/Logs，
/// 测量可释放空间并按需清空（目录保留）。底层用 WQ Files 的
/// wq_measure_tree / wq_purge_contents。
struct CacheCleanView: View {
    @EnvironmentObject private var files: FileListModel

    @State private var rows: [AppCacheRow] = []
    @State private var scanning = false
    @State private var cleaning = false
    @State private var scanText = ""
    @State private var notice: String?
    @State private var errorText: String?
    @State private var confirmCleanAll = false
    @State private var noticeToken = UUID()

    struct AppCacheRow: Identifiable {
        let id: String
        let name: String
        let path: String
        let bytes: Int64
        let targets: [Target]

        struct Target: Identifiable {
            let kind: String
            let path: String
            let bytes: Int64
            var id: String { path }
        }
    }

    private var totalBytes: Int64 {
        rows.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summaryCard

                SectionLabel(text: "可清理应用 \(rows.count)")

                if rows.isEmpty {
                    CardBox {
                        VStack(spacing: 10) {
                            Image(systemName: scanning ? "arrow.triangle.2.circlepath" : "sparkles")
                                .font(.system(size: 26, weight: .light))
                                .foregroundStyle(Palette.tertiary)
                            Text(scanning ? (scanText.isEmpty ? "正在扫描…" : scanText)
                                          : "没有发现可清理的缓存")
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                } else {
                    ForEach(rows) { row in
                        appRow(row)
                    }
                }

                if let errorText {
                    InlineNotice(text: errorText, tone: Palette.danger)
                }

                Text("只清空 Library/Caches、tmp、Library/Logs 里的内容，应用数据与文档不受影响。部分应用正在运行时可能有个别文件被占用而跳过。")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)

                Spacer(minLength: 120)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .background(Palette.background)
        .enableInteractivePop()
        .glassNavigationBar(title: "缓存清理")
        .onAppear {
            if rows.isEmpty, !scanning { scan() }
        }
        .onChange(of: notice) { _, value in
            guard value != nil else { return }
            noticeToken = UUID()
            let token = noticeToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if noticeToken == token {
                    withAnimation(.easeInOut(duration: 0.25)) { notice = nil }
                }
            }
        }
        .confirmationDialog("清理全部缓存", isPresented: $confirmCleanAll, titleVisibility: .visible) {
            Button("清理 \(sizeText(totalBytes))", role: .destructive) { cleanAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空 \(rows.count) 个应用的缓存、临时文件与日志，操作不可撤销。")
        }
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Palette.card, in: Capsule())
                    .shadow(color: Color.black.opacity(0.08), radius: 14, y: 4)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - 汇总

    private var summaryCard: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "可释放空间")
                    Text(scanning ? "扫描中" : sizeText(totalBytes))
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundStyle(Palette.ink)
                        .contentTransition(.numericText())
                    Text(scanning ? (scanText.isEmpty ? "正在扫描…" : scanText)
                                  : "\(rows.count) 个应用 · 缓存 / 临时文件 / 日志")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                }

                HStack(spacing: 10) {
                    CachePill(system: "arrow.clockwise", title: "重新扫描") {
                        scan()
                    }
                    .disabled(scanning || cleaning)

                    CachePill(system: "trash", title: "全部清理", tone: Palette.danger) {
                        confirmCleanAll = true
                    }
                    .disabled(rows.isEmpty || scanning || cleaning)

                    if cleaning {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Palette.ink)
                    }
                }
            }
        }
    }

    // MARK: - 应用行

    private func appRow(_ row: AppCacheRow) -> some View {
        // 点按进入真正被清理的缓存目录（取占用最大的那一项，通常是 Library/Caches）
        let primary = row.targets.max { $0.bytes < $1.bytes }
        let targetPath = primary?.path ?? row.path
        let targetTitle = primary.map { "\(row.name) · \($0.kind)" } ?? row.name

        return CardBox(radius: 18, padding: 0) {
            HStack(spacing: 12) {
                NavigationLink {
                    DirectoryView(route: PathRoute(path: targetPath, root: targetPath, title: targetTitle))
                } label: {
                    HStack(spacing: 12) {
                        AppIconView(bundleID: row.id, size: 40)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.name)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                            Text(targetSummary(row))
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.secondary)
                                .lineLimit(1)
                            Text(targetPath)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Palette.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer(minLength: 6)

                        Text(sizeText(row.bytes))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.ink)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    clean(row)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.danger)
                        .frame(width: 30, height: 30)
                        .background(Palette.placeholder, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(cleaning || scanning)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func targetSummary(_ row: AppCacheRow) -> String {
        row.targets
            .filter { $0.bytes > 0 }
            .map { "\($0.kind) \(sizeText($0.bytes))" }
            .joined(separator: " · ")
    }

    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - 扫描 / 清理

    private func scan() {
        guard !scanning, !cleaning else { return }
        let apps = files.apps
        guard !apps.isEmpty else {
            errorText = "应用列表为空，先到「文件」页刷新一次。"
            return
        }

        errorText = nil
        scanning = true
        rows = []
        scanText = "正在扫描 0/\(apps.count)"

        DispatchQueue.global(qos: .userInitiated).async {
            var found: [AppCacheRow] = []
            for (index, app) in apps.enumerated() {
                var targets: [AppCacheRow.Target] = []
                var total: Int64 = 0
                for item in XCTCacheOps.cacheTargets(containerPath: app.path) {
                    guard let path = item["path"] else { continue }
                    let bytes = XCTCacheOps.measureTree(path).int64Value
                    total += bytes
                    targets.append(AppCacheRow.Target(
                        kind: item["kind"] ?? "缓存",
                        path: path,
                        bytes: bytes))
                }
                if total > 0 {
                    found.append(AppCacheRow(id: app.id, name: app.name, path: app.path,
                                             bytes: total, targets: targets))
                }

                let scanned = index + 1
                let snapshot = found.sorted { $0.bytes > $1.bytes }
                DispatchQueue.main.async {
                    self.scanText = "正在扫描 \(scanned)/\(apps.count)"
                    self.rows = snapshot
                }
            }

            DispatchQueue.main.async {
                self.scanning = false
                self.scanText = ""
                self.rows = found.sorted { $0.bytes > $1.bytes }
            }
        }
    }

    private func clean(_ row: AppCacheRow) {
        guard !cleaning, !scanning else { return }
        cleaning = true
        DispatchQueue.global(qos: .userInitiated).async {
            var freed: Int64 = 0
            var skipped = 0
            for target in row.targets {
                let result = XCTCacheOps.purgeContents(of: target.path)
                if let value = result["freed"] as? NSNumber {
                    freed += value.int64Value
                } else {
                    skipped += 1
                }
            }
            DispatchQueue.main.async {
                self.cleaning = false
                self.rows.removeAll { $0.id == row.id }
                let base = "已清理 \(row.name) · 释放 \(self.sizeText(freed))"
                self.notice = skipped == 0 ? base : base + "，\(skipped) 项被跳过"
            }
        }
    }

    private func cleanAll() {
        let list = rows
        guard !list.isEmpty, !cleaning, !scanning else { return }
        cleaning = true
        DispatchQueue.global(qos: .userInitiated).async {
            var freed: Int64 = 0
            for row in list {
                for target in row.targets {
                    let result = XCTCacheOps.purgeContents(of: target.path)
                    if let value = result["freed"] as? NSNumber { freed += value.int64Value }
                }
            }
            DispatchQueue.main.async {
                self.cleaning = false
                self.rows = []
                self.notice = "已释放 \(self.sizeText(freed))"
            }
        }
    }
}

private struct CachePill: View {
    let system: String
    let title: String
    var tone: Color = Palette.ink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: system).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(tone)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Palette.placeholder, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
