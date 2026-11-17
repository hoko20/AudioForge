import SwiftUI
import UIKit

struct FilesTab: View {
    @EnvironmentObject private var files: FileListModel
    @State private var query = ""
    @State private var showLog = false

    private var visible: [AppRecord] {
        guard !query.isEmpty else { return files.apps }
        let q = query.lowercased()
        return files.apps.filter {
            $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q)
                || $0.path.lowercased().contains(q) || $0.category.contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SearchCapsule(text: $query, prompt: "搜索 App")

                    StatCard(appCount: visible.count,
                             containerCount: files.containerCount,
                             scanning: files.busy,
                             status: files.status,
                             group: files.appGroup)

                    if let error = files.errorText {
                        InlineNotice(text: error)
                    }
                    if files.declined {
                        InlineNotice(text: "上次完整扫描被拒绝，可在「设置」中允许后重试。")
                    }

                    SectionLabel(text: "应用列表")

                    if visible.isEmpty && !files.busy {
                        EmptyCard(text: "还没有应用容器。点右上角刷新；首次定位 LaunchServices 数据库可能需要几分钟。")
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(visible) { app in
                                NavigationLink(value: app) {
                                    AppCard(app: app)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        UIPasteboard.general.string = app.path
                                    } label: {
                                        Label("复制容器路径", systemImage: "doc.on.doc")
                                    }
                                }
                            }
                        }
                    }

                    Text("列表来自 LaunchServices 数据库；数据库不可读时回退到 fsgetpath 全卷扫描。点开应用后可以选择数据 / Documents / Library / tmp / 安装包 / App Group 等访问类型。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiary)
                        .padding(.top, 2)

                    Spacer(minLength: 120)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .background(Palette.background)
            .refreshable { files.refresh() }
            .enableInteractivePop()
            .glassNavigationBar(title: "文件")
            .navigationDestination(for: AppRecord.self) { app in
                AppAccessView(app: app)
            }
            .navigationDestination(for: PathRoute.self) { route in
                DirectoryView(route: route)
            }
            .navigationDestination(for: FileTarget.self) { target in
                FileView(target: target)
            }
            .overlay(alignment: .center) {
                if files.busy {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(files.status)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.secondary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            if files.busy { files.stop() } else { files.refresh() }
                        } label: {
                            Image(systemName: files.busy ? "stop.circle" : "arrow.clockwise")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Palette.ink)
                        }
                        Button { showLog = true } label: {
                            Image(systemName: "doc.text")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Palette.ink)
                        }
                    }
                }
            }
            .sheet(isPresented: $showLog) {
                DiagnosticsView(text: files.diagnostics)
            }
        }
    }
}

// MARK: - Cards

private struct StatCard: View {
    let appCount: Int
    let containerCount: Int
    let scanning: Bool
    let status: String
    let group: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text("应用数量")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                Spacer()
                Text(scanning ? "扫描中…" : "\(containerCount) 个容器")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }

            Text("\(appCount)")
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.ink)
                .padding(.top, 10)

            ThinSeparator()
                .padding(.vertical, 16)

            Text("\(appCount) 个 App · \(status)")
                .font(.system(size: 14))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)

            if group.contains("未提供") {
                Text("签名缺少 App Group，容器访问不可用")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.warning)
                    .padding(.top, 8)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.black.opacity(0.035), radius: 14, x: 0, y: 5)
    }
}

struct AppCard: View {
    let app: AppRecord

    var body: some View {
        HStack(spacing: 14) {
            AppIconView(bundleID: app.id, size: 50)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)

                    if !app.category.isEmpty {
                        Text(app.category)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.warning)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Palette.warning.opacity(0.10), in: Capsule())
                            .fixedSize()
                    }
                }
                Text(app.id)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.035), radius: 10, x: 0, y: 3)
    }
}
