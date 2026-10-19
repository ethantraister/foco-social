import SwiftUI
import UIKit

/// The tabs side by side, swiped between like Instagram's. Built on UIKit's page controller rather than a
/// SwiftUI scroll view: each tab then lays out as a full screen of its own (the keyboard pushes it up, the safe
/// areas are right), only the tab on screen stays loaded (its timers stop when you leave, as before), and tapping the
/// status bar still scrolls it to the top.
struct TabPager: UIViewControllerRepresentable {
    @Binding var selection: Int
    /// Off while a screen is pushed on top of the current tab: a sideways swipe there goes back instead (the pages'
    /// own scrolling is switched off, so it can't take the swipe from the back gesture).
    let swipeEnabled: Bool
    @Environment(MenuStore.self) private var store
    @Environment(Preferences.self) private var prefs
    @Environment(SocialStore.self) private var social

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        let coordinator = context.coordinator
        coordinator.pages = AppTab.allCases.map { tab in
            let host = UIHostingController(rootView: page(tab))
            host.view.backgroundColor = .clear
            return host
        }
        pager.view.backgroundColor = .clear
        pager.delegate = coordinator
        // Set once and left alone: UIKit's page controller can crash if its data source changes while pages move.
        pager.dataSource = coordinator
        // A tab saved by an older version (which had more of them) falls back to Together.
        let start = AppTab(rawValue: selection)?.rawValue ?? AppTab.together.rawValue
        pager.setViewControllers([coordinator.pages[start]], direction: .forward, animated: false)
        coordinator.pager = pager
        coordinator.current = start
        if let scroll = pager.view.subviews.lazy.compactMap({ $0 as? UIScrollView }).first {
            // Only the page's own list should answer a tap on the status bar.
            scroll.scrollsToTop = false
            scroll.isScrollEnabled = swipeEnabled
            coordinator.follow(scroll)
            // Sees each touch first (and never handles it), to let rows that slide open go first.
            let watcher = UIPanGestureRecognizer()
            watcher.cancelsTouchesInView = false
            watcher.delegate = coordinator
            pager.view.addGestureRecognizer(watcher)
        }
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = $selection
        coordinator.allowSwipes(swipeEnabled)
        guard selection != coordinator.shown else { return }
        coordinator.shown = selection
        for (index, host) in coordinator.pages.enumerated() { host.rootView = page(AppTab(rawValue: index)!) }
        // A tap on the bar (or a notification) jumps straight to its tab, like a normal tab bar.
        coordinator.show(selection)
    }

    private func page(_ tab: AppTab) -> TabPage {
        TabPage(tab: tab, active: selection == tab.rawValue, store: store, prefs: prefs, social: social)
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        var selection: Binding<Int>
        var pages: [UIHostingController<TabPage>] = []
        weak var pager: UIPageViewController?
        /// The page the pager is showing, and the selection the pages were last told about.
        var current = AppTab.together.rawValue
        var shown = AppTab.together.rawValue
        /// From the start of a swipe until its pages settle.
        private var swiping = false
        /// What waits for the pages to stop moving: a tab tapped mid-swipe, and swiping turned on or off.
        private var pendingTab: Int?
        private var wantsSwipes: Bool?
        private weak var scroll: UIScrollView?
        private var offsetWatch: NSKeyValueObservation?
        private let waitingOn = NSHashTable<UIGestureRecognizer>.weakObjects()

        init(selection: Binding<Int>) {
            self.selection = selection
            shown = selection.wrappedValue
        }

        /// UIKit's page controller can crash if its pages are swapped, or its scrolling switched, while they're still moving.
        private var moving: Bool {
            guard let scroll else { return false }
            return swiping || scroll.isTracking || scroll.isDragging || scroll.isDecelerating
        }

        /// Jumps straight to a tab, once the pages are still.
        func show(_ index: Int) {
            guard pages.indices.contains(index), index != current else { pendingTab = nil; return }
            guard let pager, !moving else { pendingTab = index; return }
            pendingTab = nil
            pager.setViewControllers([pages[index]], direction: index > current ? .forward : .reverse, animated: false)
            current = index
        }

        /// Swiping between tabs is off while a screen is pushed on top of the current one.
        func allowSwipes(_ on: Bool) {
            guard let scroll, scroll.isScrollEnabled != on || wantsSwipes != nil else { return }
            guard !moving else { wantsSwipes = on; return }
            wantsSwipes = nil
            scroll.isScrollEnabled = on
        }

        /// Catches up on whatever waited for the pages to stop.
        private func settle() {
            guard !moving else { return }
            if let on = wantsSwipes { allowSwipes(on) }
            if let tab = pendingTab { show(tab) }
        }

        func pageViewController(_ pager: UIPageViewController, viewControllerBefore page: UIViewController) -> UIViewController? {
            guard let index = pages.firstIndex(where: { $0 === page }), index > 0 else { return nil }
            return pages[index - 1]
        }

        func pageViewController(_ pager: UIPageViewController, viewControllerAfter page: UIViewController) -> UIViewController? {
            guard let index = pages.firstIndex(where: { $0 === page }), index < pages.count - 1 else { return nil }
            return pages[index + 1]
        }

        func pageViewController(_ pager: UIPageViewController, willTransitionTo pending: [UIViewController]) {
            swiping = true
        }

        func pageViewController(_ pager: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            swiping = false
            TabBarState.shared.swipe = nil
            if completed, let page = pager.viewControllers?.first, let index = pages.firstIndex(where: { $0 === page }) {
                current = index
                // A tab tapped mid-swipe wins over the page the swipe landed on.
                if pendingTab == nil || pendingTab == index {
                    pendingTab = nil
                    selection.wrappedValue = index
                }
            }
            // Not from inside UIKit's own transition.
            DispatchQueue.main.async { [weak self] in self?.settle() }
        }

        /// While a finger moves the pages, tells the bar where they are, so its highlight follows along.
        func follow(_ scroll: UIScrollView) {
            self.scroll = scroll
            offsetWatch = scroll.observe(\.contentOffset) { [weak self] scroll, _ in
                MainActor.assumeIsolated { self?.moved(scroll) }
            }
        }

        /// Rows that slide open (Remove, Unfollow, Alert me) get first go at a sideways swipe that starts on them:
        /// the pages only move if the row has nothing on that side. Lists make their row-swipe recognizers lazily,
        /// so this looks for them as each touch lands, before any swipe can start.
        func gestureRecognizer(_ watcher: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view, !(current is UICollectionView) { view = current.superview }
            guard let list = view as? UICollectionView, let pagesPan = scroll?.panGestureRecognizer else { return false }
            for other in list.gestureRecognizers ?? [] where other is UIPanGestureRecognizer
                && other !== list.panGestureRecognizer && !waitingOn.contains(other) {
                pagesPan.require(toFail: other)
                waitingOn.add(other)
            }
            return false
        }

        private func moved(_ scroll: UIScrollView) {
            let width = scroll.bounds.width
            guard width > 0 else { return }
            guard scroll.isDragging || scroll.isDecelerating else {
                if TabBarState.shared.swipe != nil { TabBarState.shared.swipe = nil }
                // Back at rest, in case UIKit didn't say a swipe ended (it can skip that on very quick swipes).
                if swiping, !scroll.isTracking, abs(scroll.contentOffset.x - width) < 0.5 {
                    swiping = false
                    DispatchQueue.main.async { [weak self] in self?.settle() }
                }
                return
            }
            // The page on screen sits one screen in, with its neighbors either side.
            let at = CGFloat(current) + (scroll.contentOffset.x - width) / width
            TabBarState.shared.swipe = min(max(at, 0), CGFloat(pages.count - 1))
        }
    }
}

/// One tab's page. Pages are hosted on their own, so they're handed the app's stores and tint here.
struct TabPage: View {
    let tab: AppTab
    let active: Bool
    let store: MenuStore
    let prefs: Preferences
    let social: SocialStore

    var body: some View {
        content
            .tabContent()
            .environment(\.tabIsActive, active)
            .environment(\.pagerTab, tab)
            .environment(store)
            .environment(prefs)
            .environment(social)
            .tint(.dartmouthGreen)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .menu: MenuView()
        case .together:
            SignInGate(reason: "See which friends are at Foco right now, make meal plans, and get invited to team dinners.") { TogetherView() }
        case .me: MeView()
        }
    }
}
