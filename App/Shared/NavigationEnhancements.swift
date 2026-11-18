import SwiftUI
import UIKit
import ObjectiveC

// MARK: - Edge-swipe back gesture
//
// Hiding the system back button (we draw our own "返回" button) makes
// SwiftUI disable UINavigationController.interactivePopGestureRecognizer.
// Re-enabling it needs a delegate that refuses to begin at the root, or a
// swipe on the root screen leaves the UI in a half-popped state.
private var popGestureDelegateKey: UInt8 = 0

private final class PopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var navigationController: UINavigationController?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let nav = navigationController else { return false }
        return nav.viewControllers.count > 1
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Keep the edge pan exclusive; ScrollView's vertical pan still works
        // because the system edge gesture only claims the first ~20 pt.
        return false
    }
}

private func deepestNavigationController(in controller: UIViewController) -> UINavigationController? {
    if let nav = controller as? UINavigationController {
        if let presented = nav.presentedViewController,
           let deeper = deepestNavigationController(in: presented) { return deeper }
        return nav
    }
    for child in controller.children {
        if let found = deepestNavigationController(in: child) { return found }
    }
    if let presented = controller.presentedViewController {
        return deepestNavigationController(in: presented)
    }
    return nil
}

final class PopGestureHostController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.isHidden = true
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        configure()
    }

    /// SwiftUI resets the recognizer's delegate on every navigation update,
    /// so this runs from both viewDidAppear and updateUIViewController.
    func configure() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let nav: UINavigationController?
            if let direct = self.navigationController {
                nav = direct
            } else if let root = self.view.window?.rootViewController {
                nav = deepestNavigationController(in: root)
            } else {
                nav = nil
            }
            guard let nav = nav else { return }
            let gesture = nav.interactivePopGestureRecognizer
            let existing = objc_getAssociatedObject(nav, &popGestureDelegateKey) as? PopGestureDelegate
            if let existing = existing, existing.navigationController === nav {
                gesture?.isEnabled = true
                return
            }
            let delegate = PopGestureDelegate()
            delegate.navigationController = nav
            gesture?.isEnabled = true
            gesture?.delegate = delegate
            objc_setAssociatedObject(nav, &popGestureDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

struct PopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PopGestureHostController {
        PopGestureHostController()
    }

    func updateUIViewController(_ uiViewController: PopGestureHostController, context: Context) {
        uiViewController.configure()
    }
}

// MARK: - View modifiers

extension View {
    /// Attach to any view inside a NavigationStack to restore the standard
    /// left-edge swipe-back gesture while using a custom back button.
    func enableInteractivePop() -> some View {
        background(
            PopGestureEnabler()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }

    /// iOS 26 large-title navigation bar. At the top the title sits large and
    /// left-aligned; as the ScrollView slides under it the bar collapses the
    /// title to a centered, compact form with the system "liquid glass" blur.
    /// The caller must NOT also render a custom big title inside the scroll
    /// content, or the two titles stack.
    func glassNavigationBar(title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.automatic, for: .navigationBar)
    }
}
