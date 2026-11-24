# Contributing to Nook

Thanks for wanting to make Nook better! Bug reports, ideas, design feedback and code are all welcome.

## Ways to help

- **Report a bug** — open an issue with the *Bug report* form. A screenshot or short screen recording of the notch makes most UI bugs easy to fix.
- **Suggest a feature** — use the *Feature request* form, or start a thread in Discussions.
- **Pick up an issue** — look for `good first issue` and `help wanted`. Comment on the issue first so work isn't duplicated.
- **Translate, design, document** — icons, copy, README screenshots and translations count too.

## Development setup

Requirements: macOS 15+, Xcode command line tools (Swift 6 toolchain).

```bash
git clone https://github.com/siliconile/Nook.git
cd Nook
./build.sh debug && open build/Nook.app      # or ./build.sh for a release build
```

Restart after each rebuild with `pkill -x Nook; open build/Nook.app`.
You can also open `Package.swift` in Xcode to browse and edit the code (run the app with `./build.sh`, since the bundle needs its Info.plist, icon and helper).

Useful while working on UI:

- `.build/debug/Nook --snapshot /tmp/nook-shots` renders every notch state to PNGs.
- All sizes, spacing, colours and animation timings live in `Sources/Nook/UI/Theme.swift`.

## Project structure

| Path | What lives there |
| --- | --- |
| `Sources/Nook/Core` | `NookState` (single source of truth), the notch window controller, preferences |
| `Sources/Nook/UI` | Root notch view, the animated silhouette, design tokens, Settings |
| `Sources/Nook/Modules/<Name>` | One folder per feature: model (`@MainActor` singleton) + SwiftUI view |
| `Helper/` | `NookMediaBridge.m`, the Now Playing helper loaded via `/usr/bin/perl` |
| `scripts/`, `Tools/` | Release packaging, icon generator |

### Adding a module

1. Create `Sources/Nook/Modules/<Name>/<Name>.swift` with a model (`@MainActor final class … : ObservableObject` with `static let shared`) and a view.
2. Add a case to `NookTab` (title, SF Symbol, preference key) in `Core/NookState.swift`, a key in `Core/Pref.swift`, and a toggle in `UI/SettingsView.swift`.
3. Show it in the `switch` in `UI/NotchRootView.swift`.
4. If its height depends on content, extend `openHeight(for:)` using `ListMetrics`.
5. Transient alerts go through `NookState.shared.show(NookActivity(...))`.

## Pull requests

1. Fork, then create a branch: `git checkout -b fix/short-description`.
2. Keep the change focused; one feature or fix per PR.
3. Match the existing style: Swift 5 language mode, tokens from `Theme`, no new third-party dependencies without discussing first.
4. Make sure `./build.sh` succeeds (CI builds every PR for Apple silicon and Intel).
5. For UI changes, attach before/after screenshots.
6. Add a line under **Unreleased** in `CHANGELOG.md`.

## Releasing (maintainers)

1. Move the **Unreleased** notes in `CHANGELOG.md` under the new version.
2. Tag and push: `git tag v0.2.0 && git push origin v0.2.0`.
3. The *Release* workflow builds a universal app, zips it, and publishes a GitHub Release with checksums.

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE), and to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
