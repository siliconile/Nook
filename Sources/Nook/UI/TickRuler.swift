import AppKit
import SwiftUI

/// Horizontal ruler wheel: one tick per step, a labelled tick every `majorEvery` steps,
/// the value under the centre marker. Used by the Focus timer (minutes) and the reminder
/// time picker (quarter hours). Animatable, so snapping glides.
struct TickRuler: View, Animatable {
    var value: Double
    let range: ClosedRange<Int>
    var majorEvery = 5
    let tint: Color
    var pointsPerStep: CGFloat = 13
    let label: (Int) -> String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Canvas { ctx, size in
            let mid = size.width / 2
            let span = Int(size.width / pointsPerStep / 2) + 2
            let center = Int(value.rounded())
            let tickBottom = size.height - 12
            for step in (center - span)...(center + span) where range.contains(step) {
                let x = mid + CGFloat(Double(step) - value) * pointsPerStep
                let distance = abs(x - mid) / mid           // 0 at the centre, 1 at the edges
                let fade = max(0.12, 1 - distance * 0.9)
                let major = step % majorEvery == 0
                let isCurrent = step == center
                let height: CGFloat = isCurrent ? 30 : (major ? 24 : 14)
                let width: CGFloat = isCurrent ? 2.5 : (major ? 2 : 1)
                let color: Color = isCurrent
                    ? Color(red: 1, green: 0.93, blue: 0.8)
                    : (distance < 0.35 ? tint : Color.white).opacity(fade * (major ? 0.9 : 0.5))
                let rect = CGRect(x: x - width / 2, y: tickBottom - height, width: width, height: height)
                ctx.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(color))
                if major {
                    let text = Text(label(step))
                        .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(tint.opacity(fade))
                    ctx.draw(text, at: CGPoint(x: x, y: 9))
                }
            }
            var marker = Path()
            marker.move(to: CGPoint(x: mid, y: size.height - 9))
            marker.addLine(to: CGPoint(x: mid - 5, y: size.height - 2))
            marker.addLine(to: CGPoint(x: mid + 5, y: size.height - 2))
            marker.closeSubpath()
            ctx.fill(marker, with: .color(tint))
        }
    }
}

/// Catches scroll-wheel, trackpad and drag input over a `TickRuler`.
/// Mouse wheel: one step per notch. Trackpad / drag: follows the fingers, then `onEnd`.
struct WheelInput: NSViewRepresentable {
    var pointsPerStep: CGFloat = 13
    /// Change in steps; `animated` for discrete steps (mouse wheel).
    let onChange: (Double, Bool) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> InputView {
        let v = InputView()
        updateNSView(v, context: context)
        return v
    }

    func updateNSView(_ v: InputView, context: Context) {
        v.onChange = onChange
        v.onEnd = onEnd
        v.pointsPerStep = Double(pointsPerStep)
    }

    final class InputView: NSView {
        var onChange: ((Double, Bool) -> Void)?
        var onEnd: (() -> Void)?
        var pointsPerStep = 13.0

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func scrollWheel(with e: NSEvent) {
            let dx = Double(e.scrollingDeltaX), dy = Double(e.scrollingDeltaY)
            let delta = abs(dx) > abs(dy) ? dx : dy
            if e.hasPreciseScrollingDeltas {
                // Trackpad / Magic Mouse: content follows the fingers.
                if delta != 0 { onChange?(-delta / pointsPerStep, false) }
                let done = e.momentumPhase == .ended
                    || (e.phase == .ended && e.momentumPhase == []) || e.phase == .cancelled
                if done { onEnd?() }
            } else if delta != 0 {
                // Classic wheel: one step per notch.
                onChange?(delta > 0 ? -1 : 1, true)
            }
        }

        override func mouseDragged(with e: NSEvent) {
            onChange?(-Double(e.deltaX) / pointsPerStep, false)
        }

        override func mouseUp(with e: NSEvent) { onEnd?() }
    }
}

/// A `TickRuler` you can scroll, drag or wheel; snaps to whole steps.
/// `value` is the committed step; `onCommit` fires each time it changes.
struct WheelPicker: View {
    let value: Int
    let range: ClosedRange<Int>
    var majorEvery = 5
    let tint: Color
    var pointsPerStep: CGFloat = 13
    var enabled = true
    /// Shown instead of `value` while disabled (e.g. a running countdown).
    var displayValue: Double? = nil
    let label: (Int) -> String
    let onCommit: (Int) -> Void

    @State private var wheel: Double?

    var body: some View {
        let shown = displayValue ?? wheel ?? Double(value)
        ZStack {
            TickRuler(value: shown, range: range, majorEvery: majorEvery, tint: tint,
                      pointsPerStep: pointsPerStep, label: label)
            // Native input view; ImageRenderer can't draw it, so leave it out of snapshots.
            if enabled && !Snapshot.isRendering {
                WheelInput(pointsPerStep: pointsPerStep, onChange: nudge, onEnd: snap)
            }
        }
        .onChange(of: value) { _, v in
            guard wheel == nil || Int(wheel!.rounded()) != v else { return }
            withAnimation(.spring(duration: 0.3)) { wheel = Double(v) }
        }
    }

    private func nudge(_ steps: Double, animated: Bool) {
        let current = wheel ?? Double(value)
        let next = min(Double(range.upperBound), max(Double(range.lowerBound), current + steps))
        let crossed = Int(next.rounded()) != Int(current.rounded())
        if animated {
            withAnimation(.spring(duration: 0.25, bounce: 0.15)) { wheel = next.rounded() }
        } else {
            wheel = next
        }
        if crossed {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            onCommit(Int(next.rounded()))
        }
    }

    private func snap() {
        guard let w = wheel else { return }
        withAnimation(.spring(duration: 0.3, bounce: 0.2)) { wheel = w.rounded() }
        onCommit(Int(w.rounded()))
    }
}
