import SwiftUI

/// Picker shown after tapping an app. Each row is one of Filza's "访问类型":
/// the data container and its standard sub-folders, the installed .app bundle
/// (read-only), and every App Group container the app participates in. Selecting
/// a row opens the directory browser rooted at that location.
struct AppAccessView: View {
    let app: AppRecord

    @State private var types: [AccessTypeRecord] = []
    @State private var busy = true
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    AppIconView(bundleID: app.id, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(2)
                        Text(app.id)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                }
                .padding(16)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                SectionLabel(text: "访问类型")

                if busy {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在定位可访问位置…")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.secondary)
                    }
                    .padding(16)
                } else if types.isEmpty {
                    EmptyCard(text: "没有发现可访问的容器位置，请返回重试或查看日志。")
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(types) { type in
                            NavigationLink(value: PathRoute(path: type.path, root: type.path, title: type.label)) {
                                AccessTypeRow(type: type)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let note { InlineNotice(text: note) }

                Spacer(minLength: 120)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Palette.background)
        .glassNavigationBar(title: "访问类型")
        .task { load() }
    }

    private func load() {
        busy = true
        let container = app.path
        let bid = app.id
        DispatchQueue.global(qos: .userInitiated).async {
            let raw = XCTFileOps.accessTypes(containerPath: container, bundleID: bid)
            var result: [AccessTypeRecord] = []
            for d in raw {
                guard let label = d["label"] as? String,
                      let path = d["path"] as? String,
                      let kind = d["kind"] as? String else { continue }
                let ro = (d["readOnly"] as? NSNumber)?.boolValue ?? false
                result.append(AccessTypeRecord(label: label, path: path, kind: kind, readOnly: ro))
            }
            DispatchQueue.main.async {
                self.types = result
                self.busy = false
            }
        }
    }
}

private struct AccessTypeRow: View {
    let type: AccessTypeRecord

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(type.kind == "bundle" ? Palette.placeholder : Palette.selected)
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.ink)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(type.label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text(type.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if type.readOnly {
                Text("只读")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.warning)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Palette.warning.opacity(0.1), in: Capsule())
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.03), radius: 8, x: 0, y: 2)
    }

    private var symbol: String {
        switch type.kind {
        case "docs": return "doc.text"
        case "library": return "books.vertical"
        case "tmp": return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case "bundle": return "shippingbox"
        case "group": return "person.2"
        default: return "folder.fill"
        }
    }
}
