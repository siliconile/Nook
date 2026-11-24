import SwiftUI
import UniformTypeIdentifiers

struct NotchRootView: View {
    @EnvironmentObject var state: NookState
    // Observed so the closed notch grows/shrinks when these change.
    @ObservedObject private var nowPlaying = NowPlayingModel.shared
    @ObservedObject private var pomodoro = PomodoroModel.shared
    @AppStorage(Pref.nowPlaying) private var nowPlayingEnabled = true

    var body: some View {
        let size = state.contentSize
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                shape
                    .fill(Color.black)
                    .shadow(color: .black.opacity(state.isOpen ? 0.45 : 0), radius: 12, y: 4)

                Group {
                if state.isOpen {
                    ExpandedView()
                        .padding(.horizontal, 24)
                        .padding(.top, state.notchSize.height + 2)
                        .padding(.bottom, 12)
                        .frame(width: NookState.openSize.width, height: NookState.openSize.height)
                        .transition(.identity) // no fade: the growing shape reveals it
                } else {
                    closedContent
                        .frame(height: state.notchSize.height)
                        .padding(.horizontal, state.closedSideWidth == NookState.compactSideWidth ? 8 : 14)
                        .transition(.identity)
                }
                }
                .clipShape(shape) // keep content inside the silhouette while it animates
            }
            .frame(width: size.width, height: size.height)
            .scaleEffect(state.isHovering && !state.isOpen ? 1.06 : 1, anchor: .top)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: state.isHovering)
            .onDrop(of: [UTType.fileURL], isTargeted: $state.isDropTargeted) { providers in
                guard UserDefaults.standard.bool(forKey: Pref.shelf) else { return false }
                ShelfStore.shared.add(providers: providers)
                state.open(tab: .shelf)
                return true
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    private var shape: NotchShape {
        NotchShape(topRadius: state.isOpen ? 10 : 6, bottomRadius: state.isOpen ? 28 : 12)
    }

    /// Leading/trailing content beside the hardware notch while closed.
    @ViewBuilder private var closedContent: some View {
        HStack(spacing: 0) {
            if let a = state.activity {
                Image(systemName: a.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(a.tint)
                    .frame(width: NookState.sideWidth - 14, alignment: .leading)
                Spacer(minLength: state.notchSize.width)
                Group {
                    if let progress = a.progress, let text = a.trailingText {
                        // e.g. battery: short bar + percentage
                        HStack(spacing: 5) {
                            Capsule().fill(.white.opacity(0.2))
                                .overlay(alignment: .leading) {
                                    GeometryReader { g in
                                        Capsule().fill(a.tint).frame(width: g.size.width * max(0, min(1, progress)))
                                    }
                                }
                                .frame(height: 5)
                            Text(text).font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .lineLimit(1).fixedSize()
                        }
                    } else if let progress = a.progress {
                        Capsule().fill(.white.opacity(0.2))
                            .overlay(alignment: .leading) {
                                GeometryReader { g in
                                    Capsule().fill(a.tint).frame(width: g.size.width * max(0, min(1, progress)))
                                }
                            }
                            .frame(height: 5)
                    } else if let text = a.trailingText ?? a.title {
                        Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                .frame(width: NookState.sideWidth - 20, alignment: .trailing)
            } else if pomodoro.isRunning {
                Image(systemName: pomodoro.phase.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(pomodoro.phase.tint)
                    .frame(width: NookState.sideWidth - 14, alignment: .leading)
                Spacer(minLength: state.notchSize.width)
                Text(pomodoro.remainingText)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(pomodoro.phase.tint)
                    .frame(width: NookState.sideWidth - 20, alignment: .trailing)
            } else if nowPlayingEnabled && nowPlaying.isPlaying {
                NowPlayingCompactLeading()
                    .frame(width: NookState.compactSideWidth - 8, alignment: .leading)
                Spacer(minLength: state.notchSize.width)
                NowPlayingCompactTrailing()
                    .frame(width: NookState.compactSideWidth - 8, alignment: .trailing)
            }
        }
        .foregroundStyle(.white)
    }
}

/// Expanded notch: tab bar + selected module.
struct ExpandedView: View {
    @EnvironmentObject var state: NookState

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(state.enabledTabs) { tab in
                    Button { state.selectedTab = tab } label: {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 30, height: 24)
                            .background(state.selectedTab == tab ? Color.white.opacity(0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(state.selectedTab == tab ? .white : .white.opacity(0.55))
                            .contentShape(Rectangle()) // whole tab is clickable, not just the glyph
                    }
                    .buttonStyle(.plain)
                    .help(tab.title)
                }
                Spacer()
                Text(state.selectedTab.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                Button { AppDelegate.shared?.openSettings() } label: {
                    Image(systemName: "gearshape").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.55))
            }

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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .onAppear {
            if !state.enabledTabs.contains(state.selectedTab), let first = state.enabledTabs.first {
                state.selectedTab = first
            }
        }
    }
}
