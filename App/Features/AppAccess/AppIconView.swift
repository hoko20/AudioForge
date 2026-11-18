import SwiftUI
import UIKit

// Icons require disk IO and sandbox grants, so they are resolved on a single
// serial background queue and cached as UIImages. Serialising the work keeps
// the token LRU inside WQAccess from being flooded when the list first appears.
final class IconCache {
    static let shared = IconCache()

    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "sandboxaccess.icons", qos: .userInitiated)

    private init() {
        cache.countLimit = 256
    }

    func cached(_ id: String) -> UIImage? {
        cache.object(forKey: id as NSString)
    }

    /// Called after an icon probe or a cache clear so visible cells reload
    /// with the freshly resolved bitmaps.
    func invalidateAll() {
        cache.removeAllObjects()
    }

    func image(for id: String) async -> UIImage? {
        if let hit = cached(id) { return hit }
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            queue.async {
                let resolved: UIImage? = autoreleasepool {
                    guard let data = XCTContainerBridge.iconPNG(bundleID: id) else { return nil }
                    return UIImage(data: data, scale: 2.0)
                }
                if let resolved {
                    self.cache.setObject(resolved, forKey: id as NSString)
                }
                continuation.resume(returning: resolved)
            }
        }
    }
}

struct AppIconView: View {
    let bundleID: String
    let size: CGFloat
    /// Bump to force a reload after a diagnostic re-resolution.
    var refreshToken: Int = 0

    @State private var image: UIImage?

    init(bundleID: String, size: CGFloat = 50, refreshToken: Int = 0) {
        self.bundleID = bundleID
        self.size = size
        self.refreshToken = refreshToken
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: tileColors, startPoint: .top, endPoint: .bottom))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: size * 0.40, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .task(id: "\(bundleID)#\(refreshToken)") {
            if let hit = IconCache.shared.cached(bundleID) {
                image = hit
                return
            }
            image = await IconCache.shared.image(for: bundleID)
        }
    }

    /// Deterministic per-app colour so a not-yet-resolved icon still reads as
    /// a distinct app tile instead of a flat grey square.
    private var tileColors: [Color] {
        var hash: UInt64 = 1469598103934665603
        for byte in bundleID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        let hue = Double(hash % 360) / 360.0
        let hue2 = (hue + 0.07).truncatingRemainder(dividingBy: 1.0)
        return [
            Color(hue: hue, saturation: 0.52, brightness: 0.95),
            Color(hue: hue2, saturation: 0.66, brightness: 0.78)
        ]
    }
}
