import SwiftUI

/// Shared design tokens. Every module view should use these instead of literals so
/// sizes, spacing and type stay consistent across the notch.
enum Theme {
    // MARK: Layout
    /// Horizontal inset of expanded content from the notch edge.
    static let hPad: CGFloat = 22
    /// Gap between the notch strip (tab bar row) and module content.
    static let topGap: CGFloat = 10
    static let bottomPad: CGFloat = 18
    static let spacing: CGFloat = 10
    static let smallSpacing: CGFloat = 6

    // MARK: Shape
    static let openTopRadius: CGFloat = 12
    static let openBottomRadius: CGFloat = 30
    static let closedTopRadius: CGFloat = 6
    static let closedBottomRadius: CGFloat = 13
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
    /// Backdrop blur around the open notch: how far it extends and how soft its edge is.
    static let blurOutset: CGFloat = 26
    static let blurFeather: CGFloat = 14

    // MARK: Type
    static let title = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let secondary = Font.system(size: 12)
    static let caption = Font.system(size: 11, weight: .medium)
    static let mono = Font.system(size: 11, weight: .medium).monospacedDigit()

    // MARK: Icons
    static let tabIcon: CGFloat = 13
    static let controlIcon: CGFloat = 20      // primary transport / timer controls
    static let rowIcon: CGFloat = 15          // checkboxes, row actions
    static let smallIcon: CGFloat = 11

    // MARK: Colors (on black)
    static let primary = Color.white
    static let secondaryText = Color.white.opacity(0.55)
    static let tertiaryText = Color.white.opacity(0.35)
    static let fill = Color.white.opacity(0.07)
    static let fillStrong = Color.white.opacity(0.13)
    static let separator = Color.white.opacity(0.08)

    // MARK: Motion
    /// Shape size changes.
    static let shapeSpring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let closeSpring = Animation.spring(response: 0.34, dampingFraction: 0.92)
    /// Content appears only once the shape has (almost) finished growing.
    static let contentIn = Animation.easeOut(duration: 0.18).delay(0.2)
}

/// Content reveal: slight blur + scale from the top, applied after the shape expands.
/// Removal is instant so content never sits outside a shrinking shape.
extension AnyTransition {
    static var notchContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: RevealModifier(progress: 0), identity: RevealModifier(progress: 1))
                .animation(Theme.contentIn),
            removal: .identity
        )
    }
}

private struct RevealModifier: ViewModifier {
    var progress: Double
    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 6)
            .scaleEffect(0.96 + 0.04 * progress, anchor: .top)
    }
}

/// Plain icon button with a full-size hit area and a hover highlight.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = Theme.rowIcon
    var frame: CGFloat = 28
    var tint: Color = Theme.primary
    var help: String? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: frame, height: frame)
                .background(hover ? Theme.fillStrong : .clear, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help ?? "")
    }
}
