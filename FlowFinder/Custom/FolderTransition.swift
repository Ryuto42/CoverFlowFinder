import SwiftUI

/// A short fade and slide when a pane shows another folder: in from the right going down into a
/// folder, from the left going up. Quick enough that nothing waits on it; the content is usable at once.
struct FolderTransition: ViewModifier {
    let path: URL
    let key: String
    /// The new folder's items are in: the animation waits for them, so a slow folder doesn't pop in afterwards.
    let isReady: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 1
    @State private var direction: CGFloat = 0
    @State private var lastPath: URL?
    @State private var isPending = false

    private static let duration = 0.18
    private static let distance: CGFloat = 7

    func body(content: Content) -> some View {
        content
            .opacity(0.35 + 0.65 * progress)
            .offset(x: reduceMotion ? 0 : direction * Self.distance * (1 - progress))
            .onAppear { lastPath = path }
            .onChange(of: key) { _, _ in
                direction = Self.direction(from: lastPath, to: path)
                lastPath = path
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { progress = 0 }
                isPending = true
                if isReady { animateIn() }
            }
            .onChange(of: isReady) { _, ready in
                if ready && isPending { animateIn() }
            }
    }

    private func animateIn() {
        isPending = false
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: Self.duration)) { progress = 1 }
        }
    }

    private static func direction(from old: URL?, to new: URL) -> CGFloat {
        guard let old else { return 0 }
        let oldParts = old.standardizedFileURL.pathComponents
        let newParts = new.standardizedFileURL.pathComponents
        if newParts.count > oldParts.count, Array(newParts.prefix(oldParts.count)) == oldParts { return 1 }
        if oldParts.count > newParts.count, Array(oldParts.prefix(newParts.count)) == newParts { return -1 }
        return 0
    }
}
