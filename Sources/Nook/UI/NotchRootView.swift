import SwiftUI
import UniformTypeIdentifiers

struct NotchRootView: View {
    @EnvironmentObject var state: NookState
    // Observed so the closed notch grows/shrinks when these change.
    @ObservedObject private var nowPlaying = NowPlayingModel.shared
    @ObservedObject private var pomodoro = PomodoroModel.shared
    @AppStorage(Pref.nowPlaying) private var nowPlayingEnabled = true

    var body: some View {
        // Closed outline (hardware notch + optional wings), slightly larger on hover.
        let closed = state.closedContentSize(hovering: state.isHovering)
        let open = NookState.openSize
        let progress: CGFloat = state.isOpen ? 1 : 0
        let silhouette = NotchSilhouette(progress: progress, closedSize: closed, openSize: open)

        ZStack(alignment: .top) {
            // Feathered blur of the desktop around the open notch.
            BackdropBlur()
                .mask(
                    NotchSilhouette(progress: progress, closedSize: closed, openSize: open, outset: Theme.blurOutset)
                        .fill(Color.white)
                        .blur(radius: Theme.blurFeather)
                )
                .opacity(state.isOpen ? 1 : 0)

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
                    closedContent
                        .frame(width: state.contentSize.width, height: state.notchSize.height)
                        .transition(.notchContent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .clipShape(silhouette)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(silhouette)
        .onDrop(of: [UTType.fileURL], isTargeted: $state.isDropTargeted) { providers in
            guard UserDefaults.standard.bool(forKey: Pref.shelf) else { return false }
            ShelfStore.shared.add(providers: providers)
            state.open(tab: .shelf)
            return true
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: state.isHovering)
        .preferredColorScheme(.dark)
    }

    /// Leading/trailing wings beside the hardware notch while closed.
    @ViewBuilder private var closedContent: some View {
        let side = state.closedSideWidth
        let inner = side - (side == NookState.compactSideWidth ? 6 : 10) // keep clear of the flared top corners
        HStack(spacing: 0) {
            Group {
                if let a = state.activity {
                    Image(systemName: a.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(a.tint)
                } else if pomodoro.isRunning {
                    Image(systemName: pomodoro.phase.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(pomodoro.phase.tint)
                } else if nowPlayingEnabled && nowPlaying.isPlaying {
                    NowPlayingCompactLeading()
                }
            }
            .frame(width: inner, alignment: .center)
            .padding(.leading, Theme.closedTopRadius)

            Spacer(minLength: state.notchSize.width)

            Group {
                if let a = state.activity {
                    activityTrailing(a)
                } else if pomodoro.isRunning {
                    Text(pomodoro.remainingText)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(pomodoro.phase.tint)
                        .lineLimit(1).minimumScaleFactor(0.7)
                } else if nowPlayingEnabled && nowPlaying.isPlaying {
                    NowPlayingCompactTrailing()
                }
            }
            .frame(width: inner, alignment: .center)
            .padding(.trailing, Theme.closedTopRadius)
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
            .frame(height: 5)
            .animation(.easeOut(duration: 0.15), value: progress)
    }
}

/// Expanded notch: tabs live in the strip beside the hardware notch, module below.
struct ExpandedView: View {
    @EnvironmentObject var state: NookState

    var body: some View {
        VStack(spacing: 0) {
            // Top strip: same height as the hardware notch; tabs left of it, actions right.
            HStack(spacing: 0) {
                HStack(spacing: 1) {
                    ForEach(state.enabledTabs) { tab in TabButton(tab: tab) }
                }
                Spacer(minLength: state.notchSize.width + 16)
                HStack(spacing: 2) {
                    Text(state.selectedTab.title)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                        .padding(.trailing, 4)
                    IconButton(symbol: "gearshape", size: 12, frame: 24, tint: Theme.secondaryText, help: "Settings") {
                        AppDelegate.shared?.openSettings()
                    }
                }
            }
            .frame(height: state.notchSize.height)
            // Clear the flared top corners of the shape.
            .padding(.horizontal, Theme.openTopRadius + 12)

            Group {
                switch state.selectedTab {
                case .home: NowPlayingView()
                case .tasks: TasksView()
                case .notes: NotesView()
                case .reminders: RemindersView()
                case .pomodoro: PomodoroView()
                case .shelf: ShelfView()
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
                .frame(width: 24, height: 24)
                .background(selected ? Theme.fillStrong : (hover ? Theme.fill : .clear),
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(tab.title)
    }
}
