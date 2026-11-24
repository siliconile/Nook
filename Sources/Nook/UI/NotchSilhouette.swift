import AppKit
import SwiftUI

/// The notch outline drawn inside a fixed canvas, driven by a single `progress`
/// (0 = closed, 1 = open). Because width, height and corner radii all derive from that
/// one animated value, the notch grows from its top-centre equally to the left, right
/// and downward instead of each dimension animating on its own.
struct NotchSilhouette: Shape {
    var progress: CGFloat
    var closedSize: CGSize
    var openSize: CGSize
    /// Extra growth on left/right/bottom (used for the feathered blur mask).
    var outset: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(progress, openSize.height),
                             AnimatablePair(closedSize.width, closedSize.height)) }
        set {
            progress = newValue.first.first
            openSize.height = newValue.first.second
            closedSize = CGSize(width: newValue.second.first, height: newValue.second.second)
        }
    }

    /// Current outline size (without outset).
    static func size(progress p: CGFloat, closed: CGSize, open: CGSize) -> CGSize {
        CGSize(width: closed.width + (open.width - closed.width) * p,
               height: closed.height + (open.height - closed.height) * p)
    }

    func path(in rect: CGRect) -> Path {
        let p = max(0, progress) // springs may overshoot above 1: keep it, it reads as a bounce
        let s = Self.size(progress: p, closed: closedSize, open: openSize)
        let w = s.width + outset * 2, h = s.height + outset
        let frame = CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: h)
        let top = Theme.closedTopRadius + (Theme.openTopRadius - Theme.closedTopRadius) * min(1, p)
        let bottom = Theme.closedBottomRadius + (Theme.openBottomRadius - Theme.closedBottomRadius) * min(1, p)
        return NotchShape(topRadius: top, bottomRadius: bottom + outset).path(in: frame)
    }
}

/// Behind-window blur of whatever is under the panel (desktop, other apps).
struct BackdropBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .fullScreenUI
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
