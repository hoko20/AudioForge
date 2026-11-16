import SwiftUI

@main
struct SandboxApp: App {
    @StateObject private var bookmarks = BookmarkStore()
    @StateObject private var settings = AccessSettings()
    @StateObject private var files = FileListModel()
    @StateObject private var sort = SortPreferences()
    @StateObject private var clipboard = ClipboardStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(bookmarks)
                .environmentObject(settings)
                .environmentObject(files)
                .environmentObject(sort)
                .environmentObject(clipboard)
        }
    }
}
