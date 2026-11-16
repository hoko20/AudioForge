import SwiftUI

enum AppTab: Int, CaseIterable, Identifiable {
    case files = 0
    case tools = 1
    case settings = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .files: return "文件"
        case .tools: return "工具"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .files: return "square.grid.2x2"
        case .tools: return "wrench"
        case .settings: return "gearshape"
        }
    }

    var selectedIcon: String {
        switch self {
        case .files: return "square.grid.2x2.fill"
        case .tools: return "wrench.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct RootTabView: View {
    @EnvironmentObject private var settings: AccessSettings
    @EnvironmentObject private var files: FileListModel
    @State private var selection: AppTab = .files

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.background
                .ignoresSafeArea()

            // Exactly one NavigationStack is alive at a time. Keeping all three
            // mounted makes their navigation bars fight over the same scene.
            Group {
                switch selection {
                case .files: FilesTab()
                case .tools: ToolsTab()
                case .settings: SettingsTab()
                }
            }

            FloatingTabBar(selection: $selection)
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
        }
        .tint(Palette.ink)
        .onAppear {
            XCTContainerBridge.setFullScanAllowed(settings.fullScan)
            files.refreshIfNeeded()
        }
    }
}

private struct FloatingTabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                        selection = tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        ZStack {
                            if selection == tab {
                                Circle()
                                    .fill(Palette.selected)
                                    .frame(width: 42, height: 42)
                            }
                            Image(systemName: selection == tab ? tab.selectedIcon : tab.icon)
                                .font(.system(size: 19, weight: .medium))
                                .foregroundStyle(Palette.ink)
                        }
                        .frame(width: 46, height: 42)

                        Text(tab.title)
                            .font(.system(size: 10, weight: selection == tab ? .semibold : .regular))
                            .foregroundStyle(selection == tab ? Palette.ink : Palette.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.96), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.12), radius: 20, x: 0, y: 6)
    }
}
