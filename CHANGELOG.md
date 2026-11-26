# Changelog

All notable changes to Nook are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.3.0] - 2026-11-26

### Added
- **AI Usage** tab: 5-hour and weekly limits with the next reset for Claude Code, Codex and
  Antigravity (Gemini and Claude & GPT groups). Codex is read from its local session logs,
  Claude from the Claude Code CLI login, Antigravity from `agy /usage`.
- Homebrew: `brew install --cask siliconile/tap/nook-notch` (clears the quarantine flag,
  so the first launch isn't blocked).

### Changed
- Shelf and AI Usage tabs moved to the right, beside Settings, so no tab hides behind the
  hardware notch.
- Removed the blur around the open notch.

## [0.2.1] - 2026-11-24

### Fixed
- Notes froze the app after pasting a large text: styling is now incremental (only edited
  paragraphs), layout is lazy, and the notch height no longer lays out the whole document.

## [0.2.0] - 2026-11-24

### Added
- Arabic localization (follows the system language, or per-app language in System Settings).
- Update checker: daily check of GitHub Releases, plus **Check for Updates…** in the menu.
- Settings → Now Playing shows the active source (system bridge or AppleScript fallback).
- README demo GIF, rendered from the app (`--demo-gif`).

### Changed
- Bundle identifier is now `io.github.siliconile.Nook`. Settings carry over automatically;
  macOS permissions (Accessibility for the HUD, Reminders) need to be granted once again.

## [0.1.0] - 2026-11-24

First public release.

### Added
- Notch panel that opens on hover or click, growing evenly from the centre with a feathered backdrop blur; hides in fullscreen apps.
- Now Playing for any player, including browsers, with artwork, progress and controls.
- Optional volume & brightness HUD beside the notch.
- Battery charging / unplug / low-battery alerts.
- Focus timer (Pomodoro) with a progress ring in the closed notch.
- Apple Reminders, local Tasks, Markdown Notes (live styling, smart lists, checkboxes) and a file Shelf.
- Settings: launch at login, open on hover or click, default tab, module toggles, timer lengths.
