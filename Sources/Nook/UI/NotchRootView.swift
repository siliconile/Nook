import SwiftUI
import UniformTypeIdentifiers

struct NotchRootView: View {
    @EnvironmentObject var state: NookState
    // Observed so the closed notch grows/shrinks when these change.
    @ObservedObject private var nowPlaying = NowPlayingModel.shared
    @ObservedObject private var pomodoro = PomodoroModel.shared
    @AppStorage(Pref.nowPlaying) private var nowPlayingEnabled = true
    // Observed so content-sized tabs (Tasks, Reminders, Notes) resize as they change.
    @ObservedObject private var tasks = TasksStore.shared
    @ObservedObject private var reminders = RemindersModel.shared
    @ObservedObject private var notes = NotesStore.shared
    @ObservedObject private var usage = UsageStore.shared

    var body: some View {
        // Closed outline (hardware notch + optional wings), slightly larger on hover.
        let closed = state.closedContentSize(hovering: state.isHovering)
        let open = state.openSize
        let progress: CGFloat = state.isOpen ? 1 : 0
        let silhouette = NotchSilhouette(progress: progress, closedSize: closed, openSize: open)

        ZStack(alignment: .top) {
            // Notch + its content, scaled together on hover (grows left, right and down).
            ZStack(alignment: .top) {
            silhouette
                .fill(Color.black)
                .shadow(color: .black.opacity(state.isOpen ? 0.35 : 0), radius: 12, y: 4)

            // Content is inserted with a delayed reveal (after the outline has grown) and
            // removed instantly, so it never shows outside the outline.
            ZStack(alignment: .top) {
                if state.isOpen {
                    ExpandedView()
                        .frame(width: open.width, height: open.height, alignment: .top)
                        .transition(.notchContent)
                } else if state.closedSideWidth > 0 {
                    Group {
                        if let a = state.activity, let progress = a.progress {
                            LevelWings(activity: a, progress: progress, notchWidth: state.notchSize.width)
                                .frame(width: state.contentSize.width, height: state.notchSize.height)
                        } else {
                            closedContent
                                .frame(width: state.contentSize.width, height: state.notchSize.height)
                        }
                    }
                    .transition(.notchActivity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .clipShape(silhouette)
            }
            .scaleEffect(state.isHovering && !state.isOpen ? Theme.hoverScale : 1, anchor: .top)
            .animation(Theme.hoverSpring, value: state.isHovering)
        }
        .animation(Theme.shapeSpring, value: open.height) // tab switch / content growth
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(silhouette)
        .modifier(ShelfDropTarget(enabled: !Snapshot.isRendering))
        .preferredColorScheme(.dark)
    }

    /// Leading/trailing wings beside the hardware notch while closed.
    @ViewBuilder private var closedContent: some View {
        let side = state.closedSideWidth
        // Same distance from the outer edge on both sides (past the flared top corner).
        let margin: CGFloat = Theme.closedTopRadius + (side == NookState.compactSideWidth ? 5 : 12)
        let inner = side - margin
        HStack(spacing: 0) {
            Group {
                if let a = state.activity {
                    Image(systemName: a.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(a.tint)
                } else if pomodoro.isRunning {
                    // Mini ring: share of the session still remaining.
                    ZStack {
                        Circle().stroke(pomodoro.phase.tint.opacity(0.25), lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: max(0.001, 1 - pomodoro.progress))
                            .stroke(pomodoro.phase.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: pomodoro.progress)
                    }
                    .frame(width: 14, height: 14)
                } else if nowPlayingEnabled && nowPlaying.isPlaying {
                    NowPlayingCompactLeading()
                }
            }
            .frame(width: inner, alignment: .leading)
            .padding(.leading, margin)

            Spacer(minLength: state.notchSize.width)

            Group {
                if let a = state.activity {
                    activityTrailing(a)
                } else if pomodoro.isRunning {
                    Text(pomodoro.remainingText)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(pomodoro.phase.tint)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .contentTransition(.numericText(countsDown: true))
                } else if nowPlayingEnabled && nowPlaying.isPlaying {
                    NowPlayingCompactTrailing()
                }
            }
            .frame(width: inner, alignment: .trailing)
            .padding(.trailing, margin)
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private func activityTrailing(_ a: NookActivity) -> some View {
        if let progress = a.progress {
            HStack(spacing: 5) {
                ProgressCapsule(progress: progress, tint: a.tint)
                if let text = a.trailingText {
                    Text(text).font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .lineLimit(1).fixedSize()
                }
            }
            .padding(.trailing, 6)
        } else if let text = a.trailingText ?? a.title {
            Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

/// Volume / brightness / charging row under the hardware notch.
/// Volume / brightness / charging beside the hardware notch: icon + value on the
/// left wing, segmented level on the right wing. No downward growth.
private struct LevelWings: View {
    let activity: NookActivity
    let progress: Double
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: activity.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(activity.tint)
                    .frame(width: 18)
                    .contentTransition(.symbolEffect(.replace))
                Text(activity.trailingText ?? "\(Int((max(0, min(1, progress)) * 100).rounded()))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.leading, Theme.closedTopRadius + 8)

            Spacer(minLength: notchWidth + 10)

            ProgressCapsule(progress: progress, tint: activity.tint)
                .frame(height: 5)
                .padding(.trailing, Theme.closedTopRadius + 8)
        }
    }
}

/// 16 rounded segments; the partially filled one is drawn proportionally.
private struct SegmentedLevel: View {
    let progress: Double
    let tint: Color
    private let count = 16

    var body: some View {
        let filled = max(0, min(1, progress)) * Double(count)
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { i in
                let amount = max(0, min(1, filled - Double(i)))
                Capsule().fill(Color.white.opacity(0.16))
                    .overlay(alignment: .leading) {
                        GeometryReader { g in
                            Capsule().fill(tint).frame(width: g.size.width * amount)
                        }
                    }
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.12), value: progress)
    }
}

/// Notch-wide file drop target that opens the Shelf.
private struct ShelfDropTarget: ViewModifier {
    @EnvironmentObject var state: NookState
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [UTType.fileURL], isTargeted: $state.isDropTargeted) { providers in
                guard UserDefaults.standard.bool(forKey: Pref.shelf) else { return false }
                ShelfStore.shared.add(providers: providers)
                state.open(tab: .shelf)
                return true
            }
        } else {
            content
        }
    }
}

private struct ProgressCapsule: View {
    let progress: Double
    let tint: Color
    var body: some View {
        Capsule().fill(.white.opacity(0.2))
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(tint).frame(width: g.size.width * max(0, min(1, progress)))
                }
            }
            .frame(height: 4)
            .animation(.easeOut(duration: 0.15), value: progress)
    }
}

/// Expanded notch: tabs live in the strip beside the hardware notch, module below.
struct ExpandedView: View {
    @EnvironmentObject var state: NookState

    var body: some View {
        VStack(spacing: 0) {
            // Top strip (hardware-notch height): all tabs left of the notch, settings right.
            HStack(spacing: 0) {
                HStack(spacing: 1) {
                    ForEach(state.enabledTabs.filter { !NookTab.trailing.contains($0) }) { tab in TabButton(tab: tab) }
                }
                Spacer(minLength: state.notchSize.width + 8)
                HStack(spacing: 1) {
                    // Shelf and Usage sit beside Settings so the left side clears the hardware notch.
                    ForEach(state.enabledTabs.filter { NookTab.trailing.contains($0) }) { tab in TabButton(tab: tab) }
                    IconButton(symbol: "gearshape", size: 12, frame: 22, tint: Theme.tertiaryText, help: String(localized: "Settings")) {
                        AppDelegate.shared?.openSettings()
                    }
                }
            }
            .frame(height: state.notchSize.height)
            // Clear the flared top corners of the shape.
            .padding(.horizontal, Theme.hPad - 6) // align tab glyphs with content edges

            Group {
                switch state.selectedTab {
                case .home: NowPlayingView()
                case .tasks: TasksView()
                case .notes: NotesView()
                case .reminders: RemindersView()
                case .pomodoro: PomodoroView()
                case .shelf: ShelfView()
                case .usage: UsageView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, Theme.hPad)
            .padding(.top, Theme.topGap)
            .padding(.bottom, Theme.bottomPad)
        }
        .foregroundStyle(.white)
        .onAppear {
            if !state.enabledTabs.contains(state.selectedTab), let first = state.enabledTabs.first {
                state.selectedTab = first
            }
        }
    }
}

private struct TabButton: View {
    @EnvironmentObject var state: NookState
    let tab: NookTab
    @State private var hover = false

    var body: some View {
        let selected = state.selectedTab == tab
        Button { state.selectedTab = tab } label: {
            Image(systemName: tab.symbol)
                .font(.system(size: Theme.tabIcon, weight: .semibold))
                .foregroundStyle(selected ? Theme.primary : (hover ? Theme.secondaryText : Theme.tertiaryText))
                .frame(width: 20, height: 22)
                .background(selected ? Theme.fillStrong : (hover ? Theme.fill : .clear),
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(tab.title)
    }
}
