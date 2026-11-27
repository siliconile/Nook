import SwiftUI

// MARK: - Model

/// One rolling rate-limit window (the 5-hour session or the weekly limit).
struct UsageWindow: Equatable {
    /// 0...100
    var usedPercent: Double
    var resetsAt: Date?
}

enum UsageAgent: String, CaseIterable, Identifiable {
    case claude, codex, antigravity
    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .antigravity: "arrow.up.circle"
        }
    }

    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.45, green: 0.78, blue: 0.62)
        case .antigravity: Color(red: 0.42, green: 0.62, blue: 0.98)
        }
    }
}

struct AgentUsage: Equatable {
    enum Status: Equatable {
        case loading
        case ok
        /// No credentials / no data yet; the string tells the user what to do.
        case unavailable(String)
    }

    var status: Status = .loading
    /// Quota group inside one agent (Antigravity: "Gemini", "Claude & GPT").
    var group: String? = nil
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    /// When the numbers were measured (Codex: last session event; Claude: last fetch).
    var updatedAt: Date?
}

// MARK: - Store

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    /// One or more rows per agent (Antigravity has one per quota group).
    @Published private(set) var usage: [UsageAgent: [AgentUsage]] = [:]

    private var lastRemoteFetch: Date?
    private var refreshTask: Task<Void, Never>?

    /// Rows in display order; agents not loaded yet show a loading row.
    var rows: [(agent: UsageAgent, usage: AgentUsage)] {
        UsageAgent.allCases.flatMap { agent in
            (usage[agent] ?? [AgentUsage()]).map { (agent, $0) }
        }
    }

    /// Refreshes all agents. Claude and Antigravity call out, so they are throttled.
    /// Sample numbers for the README / website renders (never the viewer's own usage).
    func showSample(_ rows: [UsageAgent: [AgentUsage]]) { usage = rows }

    func refresh(force: Bool = false) {
        guard refreshTask == nil, !Snapshot.isRendering else { return }
        let remote = force || lastRemoteFetch.map { Date().timeIntervalSince($0) > 120 } ?? true
        refreshTask = Task {
            usage[.codex] = [await Task.detached { CodexUsageSource.read() }.value]
            if remote {
                async let claude = ClaudeUsageSource.fetch()
                async let agy = Task.detached { AntigravityUsageSource.read() }.value
                usage[.claude] = [await claude]
                usage[.antigravity] = await agy
                lastRemoteFetch = Date()
            }
            refreshTask = nil
        }
    }
}

// MARK: - Codex (local session logs)

/// Codex CLI writes `rate_limits` into every `token_count` event of its session logs
/// (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl), so no network or token is needed.
/// The numbers only change while Codex is used, so the latest event is current.
enum CodexUsageSource {
    static func read() -> AgentUsage {
        // Newer Codex builds log `rate_limits: null`, so ask the app-server first.
        if let live = AppServer.readRateLimits() { return live }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let files = recentSessionFiles(in: root), !files.isEmpty else {
            return AgentUsage(status: .unavailable(String(localized: "Use the codex CLI to see usage")))
        }
        for file in files.prefix(15) {
            if let usage = latestRateLimits(in: file) { return usage }
        }
        return AgentUsage(status: .unavailable(String(localized: "No usage recorded yet")))
    }

    private static func recentSessionFiles(in root: URL) -> [URL]? {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return nil }
        var files: [(URL, Date)] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            files.append((url, date))
        }
        return files.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Scans the tail of a log backwards for the last non-null `rate_limits`.
    private static func latestRateLimits(in file: URL) -> AgentUsage? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 2 * 1024 * 1024
        try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\":{") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            var result = AgentUsage(status: .ok)
            for key in ["primary", "secondary"] {
                guard let w = limits[key] as? [String: Any] else { continue }
                let minutes = (w["window_minutes"] as? NSNumber)?.intValue ?? 0
                let window = normalized(UsageWindow(
                    usedPercent: (w["used_percent"] as? NSNumber)?.doubleValue ?? 0,
                    resetsAt: (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }))
                if minutes >= 24 * 60 { result.weekly = window } else { result.fiveHour = window }
            }
            if let ts = obj["timestamp"] as? String { result.updatedAt = parseISODate(ts) }
            return result
        }
        return nil
    }

    /// `codex app-server` (JSON-RPC over stdio) answers `account/rateLimits/read`
    /// from the account, with no conversation or tokens used.
    enum AppServer {
        static func readRateLimits() -> AgentUsage? {
            guard let codex = findExecutable("codex") else { return nil }
            let p = Process()
            p.executableURL = codex
            p.arguments = ["app-server"]
            p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            let input = Pipe(), out = Pipe()
            p.standardInput = input
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            // Writing to a pipe whose reader already exited must not kill Nook.
            signal(SIGPIPE, SIG_IGN)
            guard (try? p.run()) != nil else { return nil }
            defer { if p.isRunning { p.terminate() } }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
            defer { killer.cancel() }

            let requests = [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"nook","version":"1"}}}"#,
                #"{"jsonrpc":"2.0","method":"initialized"}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}"#,
            ]
            try? input.fileHandleForWriting.write(contentsOf: Data((requests.joined(separator: "\n") + "\n").utf8))

            var buffer = Data()
            while true {
                let chunk = out.fileHandleForReading.availableData
                if chunk.isEmpty { return nil } // EOF: exited or killed
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          (obj["id"] as? NSNumber)?.intValue == 2 else { continue }
                    guard let result = obj["result"] as? [String: Any],
                          let limits = result["rateLimits"] as? [String: Any] else { return nil }
                    var usage = AgentUsage(status: .ok, updatedAt: Date())
                    for key in ["primary", "secondary"] {
                        guard let w = limits[key] as? [String: Any] else { continue }
                        let minutes = (w["windowDurationMins"] as? NSNumber)?.intValue ?? 0
                        let window = normalized(UsageWindow(
                            usedPercent: (w["usedPercent"] as? NSNumber)?.doubleValue ?? 0,
                            resetsAt: (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }))
                        if minutes >= 24 * 60 { usage.weekly = window } else { usage.fiveHour = window }
                    }
                    return usage
                }
            }
        }
    }
}

/// GUI apps don't get the shell PATH, so look in the usual install locations.
private func findExecutable(_ name: String) -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
            "\(home)/.claude/local/\(name)"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }
}

/// A window whose reset time has passed has started over.
private func normalized(_ w: UsageWindow) -> UsageWindow {
    if let r = w.resetsAt, r < Date() { return UsageWindow(usedPercent: 0, resetsAt: nil) }
    return w
}

private func parseISODate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

// MARK: - Claude (Claude Code OAuth token → usage endpoint)

/// Uses the token the Claude Code CLI stores in the login Keychain (or
/// ~/.claude/.credentials.json) and asks the same usage endpoint `/usage` shows.
/// Nook never refreshes the token itself (that would rotate it under Claude Code);
/// when it has expired, it runs `claude -p /usage`, which costs no tokens and makes
/// Claude Code refresh and store a new one.
enum ClaudeUsageSource {
    static func fetch() async -> AgentUsage {
        let first = await fetchOnce()
        guard first.needsRefresh else { return first.usage }
        guard await Task.detached(operation: { refreshViaCLI() }).value else { return first.usage }
        return await fetchOnce().usage
    }

    private static func fetchOnce() async -> (usage: AgentUsage, needsRefresh: Bool) {
        let expired = AgentUsage(status: .unavailable(String(localized: "Session expired — run claude once to refresh")))
        guard let creds = await Task.detached(operation: { readCredentials() }).value else {
            return (AgentUsage(status: .unavailable(String(localized: "Sign in with the claude CLI to see usage"))), false)
        }
        if let expires = creds.expiresAt, expires < Date() { return (expired, true) }
        let (usage, code) = await request(creds)
        return code == 401 || code == 403 ? (expired, true) : (usage, false)
    }

    /// `claude -p /usage` is handled locally by Claude Code (0 tokens) but refreshes its login.
    private static func refreshViaCLI() -> Bool {
        guard let claude = findExecutable("claude") else { return false }
        let p = Process()
        p.executableURL = claude
        p.arguments = ["-p", "/usage", "--output-format", "json"]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        return p.terminationStatus == 0
    }

    private static func request(_ creds: Credentials) async -> (AgentUsage, Int) {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (AgentUsage(status: .unavailable(String(localized: "Couldn't load usage"))), code)
            }
            func window(_ key: String) -> UsageWindow? {
                guard let w = obj[key] as? [String: Any],
                      let used = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
                return normalized(UsageWindow(usedPercent: used, resetsAt: (w["resets_at"] as? String).flatMap(parseISODate)))
            }
            return (AgentUsage(status: .ok, fiveHour: window("five_hour"), weekly: window("seven_day"), updatedAt: Date()), code)
        } catch {
            return (AgentUsage(status: .unavailable(String(localized: "Couldn't load usage"))), 0)
        }
    }

    private struct Credentials { let token: String; let expiresAt: Date? }

    private static func readCredentials() -> Credentials? {
        // /usr/bin/security created the item for Claude Code, so it can read it without a prompt.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        var data: Data?
        if (try? p.run()) != nil {
            data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus != 0 { data = nil }
        }
        if let c = data.flatMap(parse) { return c }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        return (try? Data(contentsOf: file)).flatMap(parse)
    }

    private static func parse(_ data: Data) -> Credentials? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Credentials(token: token, expiresAt: expires)
    }
}

// MARK: - Antigravity (`agy -p /usage`)

/// `agy -p "/usage" --output-format json` prints the account quota without starting a
/// conversation or using tokens. Models are grouped; each group has a 5-hour and a
/// weekly bucket with `remaining_fraction` and `reset_time`.
enum AntigravityUsageSource {
    static func read() -> [AgentUsage] {
        guard let agy = findExecutable("agy") else {
            return [AgentUsage(status: .unavailable(String(localized: "Install the agy CLI to see usage")))]
        }
        let p = Process()
        p.executableURL = agy
        p.arguments = ["-p", "/usage", "--output-format", "json"]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else {
            return [AgentUsage(status: .unavailable(String(localized: "Couldn't load usage")))]
        }
        // Don't let a hung CLI block refreshes forever.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = obj["command"] as? [String: Any],
              let payload = command["data"] as? [String: Any],
              let groups = payload["groups"] as? [[String: Any]], !groups.isEmpty else {
            return [AgentUsage(status: .unavailable(String(localized: "Sign in with the agy CLI to see usage")))]
        }
        return groups.map { group in
            var row = AgentUsage(status: .ok, group: shortName(group["name"] as? String), updatedAt: Date())
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                let remaining = (bucket["remaining_fraction"] as? NSNumber)?.doubleValue ?? 1
                let window = normalized(UsageWindow(
                    usedPercent: max(0, min(100, (1 - remaining) * 100)),
                    resetsAt: (bucket["reset_time"] as? String).flatMap(parseISODate)))
                if (bucket["window"] as? String) == "weekly" { row.weekly = window } else { row.fiveHour = window }
            }
            return row
        }
    }

    private static func shortName(_ name: String?) -> String? {
        guard let name else { return nil }
        if name.hasPrefix("Gemini") { return "Gemini" }
        if name.hasPrefix("Claude and GPT") { return "Claude & GPT" }
        return name
    }
}

// MARK: - View

/// One row per agent (and per quota group): name | 5-hour window | weekly window.
struct UsageView: View {
    @ObservedObject private var store = UsageStore.shared
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: UsageView.rowGap) {
            ForEach(Array(store.rows.enumerated()), id: \.offset) { _, row in
                AgentUsageRow(agent: row.agent, usage: row.usage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { store.refresh() }
        .onReceive(timer) { _ in store.refresh() }
    }

    static let rowHeight: CGFloat = 40
    static let rowGap: CGFloat = 6
    /// Content height for `rowCount` rows (used by NookState to size the notch).
    static func contentHeight(rows rowCount: Int) -> CGFloat {
        CGFloat(rowCount) * rowHeight + CGFloat(max(0, rowCount - 1)) * rowGap
    }
}

private struct AgentUsageRow: View {
    let agent: UsageAgent
    let usage: AgentUsage

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: agent.symbol)
                    .font(.system(size: Theme.smallIcon, weight: .bold))
                    .foregroundStyle(agent.tint)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let group = usage.group {
                        Text(group).font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.tertiaryText).lineLimit(1)
                    }
                }
            }
            .frame(width: 96, alignment: .leading)

            switch usage.status {
            case .loading:
                ProgressView().controlSize(.mini).frame(maxWidth: .infinity, alignment: .leading)
            case .unavailable(let message):
                Text(message)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .ok:
                WindowCell(label: String(localized: "5 hours"), window: usage.fiveHour, tint: agent.tint)
                WindowCell(label: String(localized: "Week"), window: usage.weekly, tint: agent.tint)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: UsageView.rowHeight)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.controlRadius + 2, style: .continuous))
    }
}

private struct WindowCell: View {
    let label: String
    let window: UsageWindow?
    let tint: Color

    var body: some View {
        let used = window?.usedPercent ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label).foregroundStyle(Theme.secondaryText)
                Text(window == nil ? "—" : "\(Int(used.rounded()))%")
                    .font(Theme.mono)
                    .foregroundStyle(barColor(used))
                Spacer(minLength: 2)
                Text(resetText)
                    .foregroundStyle(Theme.tertiaryText)
            }
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)

            Capsule().fill(Theme.fillStrong)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(barColor(used)).frame(width: g.size.width * min(1, max(0, used / 100)))
                    }
                }
                .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
    }

    private func barColor(_ used: Double) -> Color {
        used >= 90 ? .red : used >= 70 ? .orange : tint
    }

    /// "2h 53m" within a day, otherwise weekday + time ("Wed 21:08").
    private var resetText: String {
        guard let reset = window?.resetsAt else { return String(localized: "Not started") }
        let left = reset.timeIntervalSinceNow
        if left < 24 * 3600 {
            let f = DateComponentsFormatter()
            f.allowedUnits = left < 3600 ? [.minute] : [.hour, .minute]
            f.unitsStyle = .abbreviated
            f.maximumUnitCount = 2
            return f.string(from: max(60, left)) ?? ""
        }
        return reset.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
