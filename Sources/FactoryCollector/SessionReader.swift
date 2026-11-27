import Foundation
import FactoryCore

/// Reads one session file, the Swift port of live.py's Session. The first read takes the head (meta, first
/// prompt) and the tail; after that only the bytes appended since the last poll. Read-only.
final class SessionReader {
    static let headBytes = 256 * 1024
    static let tailBytes: UInt64 = 3 * 1024 * 1024
    static let keep = 240

    let url: URL
    let provider: Provider
    var id: String
    var offset: UInt64 = 0
    var cwd: String?
    /// The folder the session started in: a `cd` later in the session does not move it to another floor (D37).
    var startCwd: String?
    var branch: String?
    var entrypoint: String?
    var title: String?
    var model: String?
    var firstPrompt: String?
    var started: Date?
    var last: Date?
    var turnOpen = false
    /// the agent's last words (the end of its last turn)
    var lastSaid: String?
    var isSubAgentSession = false
    /// The first thing said to the session, raw (also an injected block, like a scheduled task's prompt), and the folders
    /// its shell cd'd to: where a session started elsewhere says it works. Never shown, only matched against factories.
    var firstUserText: String?
    var cdTargets: Set<String> = []
    var items: [Activity] = []
    private var calls: [String: Int] = [:]

    init(url: URL, provider: Provider) {
        self.url = url
        self.provider = provider
        let base = url.deletingPathExtension().lastPathComponent
        self.id = String(base.suffix(36))
    }

    // MARK: reading

    func read() throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if size < offset { offset = 0; items = []; calls = [:] }
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var chunk: Data
        let first = offset == 0
        if first {
            let head = try fh.read(upToCount: Self.headBytes) ?? Data()
            for line in Self.lines(head, dropLast: true) { handle(line, metaOnly: true) }
            let start = size > Self.tailBytes ? size - Self.tailBytes : 0
            try fh.seek(toOffset: start)
            chunk = try fh.readToEnd() ?? Data()
            if start > 0, let nl = chunk.firstIndex(of: 10) { chunk = Data(chunk[(nl + 1)...]) }
        } else {
            try fh.seek(toOffset: offset)
            chunk = try fh.readToEnd() ?? Data()
        }
        guard let end = chunk.lastIndex(of: 10) else { return }
        for line in Self.lines(chunk[chunk.startIndex..<end], dropLast: false) { handle(line, metaOnly: false) }
        offset = first ? size - UInt64(chunk.endIndex - end) + 1 : offset + UInt64(end - chunk.startIndex) + 1
        if items.count > Self.keep { items.removeFirst(items.count - Self.keep); calls = [:] }
    }

    static func lines(_ data: Data, dropLast: Bool) -> [Data] {
        var parts = data.split(separator: 10, omittingEmptySubsequences: true).map { Data($0) }
        if dropLast, !parts.isEmpty { parts.removeLast() }
        return parts
    }

    func handle(_ raw: Data, metaOnly: Bool) {
        guard let o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return }
        provider == .claude ? claude(o, metaOnly) : codex(o, metaOnly)
    }

    // MARK: helpers

    private static let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let iso = ISO8601DateFormatter()
    static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }

    /// Words you typed yourself, not an injected system block or an attachment placeholder.
    static func isPrompt(_ text: String) -> Bool {
        let t = text.drop(while: \.isWhitespace)
        return !t.isEmpty && !["<", "[Image", "[Request interrupted", "Caveat:"].contains { t.hasPrefix($0) }
    }

    static func short(_ text: String, _ n: Int) -> String {
        let t = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return t.count <= n ? t : String(t.prefix(n - 1)) + "…"
    }

    private func add(_ at: Date?, _ kind: ActivityKind, _ text: String, call: String? = nil) {
        guard let at else { return }
        items.append(Activity(at: at, kind: kind, text: text))
        if let call { calls[call] = items.count - 1 }
        last = max(last ?? at, at)
        started = min(started ?? at, at)
    }

    private func fail(_ call: String?, _ at: Date?) {
        guard let call, let i = calls[call], i < items.count, !CommandKind.isQuietFail(items[i].text) else { return }
        items[i].failed = true
        if let at { last = max(last ?? at, at) }
    }

    private func markLastFailed() {
        guard let i = items.indices.last, !CommandKind.isQuietFail(items[i].text) else { return }
        items[i].failed = true
    }

    private func base(_ path: Any?) -> String { PathText.name(path as? String ?? "") }

    // MARK: Claude Code

    private static let editTools: Set = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    private static let readTools: Set = ["Read", "Grep", "Glob", "WebFetch", "WebSearch", "ToolSearch", "LS", "NotebookRead"]
    private static let planTools: Set = ["TodoWrite", "EnterPlanMode", "ExitPlanMode", "mcp__ccd_turn__update_plan"]

    private func claude(_ o: [String: Any], _ meta: Bool) {
        let t = o["type"] as? String, at = Self.date(o["timestamp"])
        if let c = o["cwd"] as? String, !c.isEmpty { cwd = c; if startCwd == nil { startCwd = c } }
        if let b = o["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { branch = b }
        if entrypoint == nil, let e = o["entrypoint"] as? String, !e.isEmpty { entrypoint = e }
        if t == "custom-title", let ct = o["customTitle"] as? String { title = ct }
        if t == "relocated", let rc = o["relocatedCwd"] as? String { cwd = rc; startCwd = rc }
        if o["isSidechain"] as? Bool == true { return }     // a sub-agent's own conversation
        if t == "user" {
            let content = (o["message"] as? [String: Any])?["content"]
            if firstUserText == nil {
                let raw = (content as? String) ?? ((content as? [[String: Any]])?.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.first)
                if let raw, !raw.isEmpty { firstUserText = String(raw.prefix(8000)) }
            }
            if let text = content as? String, Self.isPrompt(text) {
                if firstPrompt == nil { firstPrompt = text }
                if !meta { add(at, .prompt, Self.short(text, 80)); turnOpen = true }
            } else if let blocks = content as? [[String: Any]] {
                for b in blocks {
                    if !meta, b["type"] as? String == "tool_result", b["is_error"] as? Bool == true {
                        fail(b["tool_use_id"] as? String, at)
                    } else if b["type"] as? String == "text", let text = b["text"] as? String, Self.isPrompt(text) {
                        if firstPrompt == nil { firstPrompt = text }
                        if !meta { add(at, .prompt, Self.short(text, 80)); turnOpen = true }
                    }
                }
            }
            return
        }
        if t == "pr-link", !meta { add(at, .push, "opened PR #\(o["prNumber"].map { "\($0)" } ?? "")"); return }
        guard t == "assistant", !meta, let msg = o["message"] as? [String: Any] else { return }
        if let m = msg["model"] as? String, !m.hasPrefix("<") { model = m }
        for b in (msg["content"] as? [[String: Any]]) ?? [] where b["type"] as? String == "tool_use" {
            let name = b["name"] as? String ?? "", input = b["input"] as? [String: Any] ?? [:], call = b["id"] as? String
            if Self.editTools.contains(name) {
                let f = base(input["file_path"] ?? input["notebook_path"])
                add(at, .edit, "edited " + (f.isEmpty ? "a file" : f), call: call)
            } else if Self.readTools.contains(name) {
                let f = base(input["file_path"])
                add(at, .read, "read " + (f.isEmpty ? name.lowercased() : f), call: call)
            } else if name == "Bash" {
                noteCd(input["command"] as? String ?? "")
                let (kind, label) = CommandKind.classify(input["command"] as? String ?? "")
                add(at, kind, "ran " + label, call: call)
            } else if Self.planTools.contains(name) {
                add(at, .plan, "updated the plan", call: call)
            } else if name == "AskUserQuestion" {
                add(at, .ask, "asked you a question", call: call)
            } else if name == "Agent" || name == "Task" {
                add(at, .delegate, "started a sub-agent", call: call)
            } else if name.contains("Browser") || name.contains("chrome") {
                add(at, .browse, "checked the app in a browser", call: call)
            } else if name.hasPrefix("mcp__") {
                let parts = name.components(separatedBy: "__")
                add(at, .mcp, "used " + (parts.count > 1 ? parts[1] : "a tool"), call: call)
            } else {
                add(at, .shell, "used " + name, call: call)
            }
        }
        // An agent that uses tools is mid-turn, even when the prompt that started the turn fell outside the tail we read.
        // (live.py only opens a turn on a prompt, so a long turn in a big file looked finished there.)
        let said = ((msg["content"] as? [[String: Any]]) ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty { lastSaid = String(said.suffix(4000)) }
        if ((msg["content"] as? [[String: Any]]) ?? []).contains(where: { $0["type"] as? String == "tool_use" }) { turnOpen = true }
        if msg["stop_reason"] as? String == "end_turn" { add(at, .turnEnd, "finished its turn"); turnOpen = false }
    }

    // MARK: Codex

    private func codex(_ o: [String: Any], _ meta: Bool) {
        let t = o["type"] as? String, at = Self.date(o["timestamp"]), p = o["payload"] as? [String: Any] ?? [:]
        if t == "session_meta" {
            if let c = p["cwd"] as? String { cwd = c; if startCwd == nil { startCwd = c } }
            if let i = p["id"] as? String { id = i }
            if let g = p["git"] as? [String: Any], let b = g["branch"] as? String { branch = b }
            if let src = p["source"] as? [String: Any], src["subagent"] != nil { isSubAgentSession = true }
            return
        }
        if t == "turn_context", let c = p["cwd"] as? String { cwd = c }
        guard t == "event_msg" else { return }
        let pt = p["type"] as? String
        if pt == "thread_settings_applied", let m = (p["thread_settings"] as? [String: Any])?["model"] as? String { model = m }
        if pt == "item_completed" {
            let it = p["item"] as? [String: Any] ?? [:]
            switch it["type"] as? String {
            case "UserMessage":
                let text = ((it["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
                if firstUserText == nil, !text.isEmpty { firstUserText = String(text.prefix(8000)) }
                if Self.isPrompt(text) {
                    if firstPrompt == nil { firstPrompt = text }
                    if !meta { add(at, .prompt, Self.short(text, 80)); turnOpen = true }
                }
            case "CommandExecution" where !meta:
                let parsed = (it["parsed_cmd"] as? [[String: Any]])?.first ?? [:]
                let cmd = parsed["cmd"] as? String ?? ((it["command"] as? [String])?.joined(separator: " ") ?? "")
                noteCd(((it["command"] as? [String])?.joined(separator: " ")) ?? cmd)
                if ["read", "search", "list_files"].contains(parsed["type"] as? String ?? "") {
                    let f = base(parsed["path"] ?? parsed["name"])
                    add(at, .read, "read " + (f.isEmpty ? "files" : f))
                } else {
                    let (k, label) = CommandKind.classify(cmd)
                    add(at, k, "ran " + label)
                }
                if let code = it["exit_code"] as? Int, code != 0 { markLastFailed() }
            case "FileChange" where !meta:
                let names = ((it["changes"] as? [String: Any]) ?? [:]).keys.map { PathText.name($0) }.sorted()
                add(at, .edit, "edited " + (names.isEmpty ? "files" : names.prefix(2).joined(separator: ", ") + (names.count > 2 ? " +\(names.count - 2)" : "")))
                if it["status"] as? String == "failed" { markLastFailed() }
            case "AgentMessage" where !meta:
                let said = ((it["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n\n")
                if !said.isEmpty { lastSaid = String(said.suffix(4000)) }
            case "McpToolCall" where !meta:
                add(at, .mcp, "used " + (it["server"] as? String ?? "a tool"))
                if ((it["result"] as? [String: Any])?["isError"] as? Bool) == true { markLastFailed() }
            default: break
            }
        } else if pt == "task_started", !meta {
            turnOpen = true
            if let at { last = max(last ?? at, at) }
        } else if pt == "task_complete", !meta {
            if let m = p["last_agent_message"] as? String, !m.isEmpty { lastSaid = String(m.suffix(4000)) }
            add(at, .turnEnd, "finished its turn"); turnOpen = false
        }
    }

    /// "cd /path/to/x && npm test" → /path/to/x
    private func noteCd(_ command: String) {
        guard command.contains("cd ") else { return }
        let re = try! NSRegularExpression(pattern: #"(?:^|&&|;|\|\||\(|\s)cd\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|)]+))"#)
        let ns = command as NSString
        for m in re.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
            for k in 1...3 where m.range(at: k).location != NSNotFound { cdTargets.insert(ns.substring(with: m.range(at: k))) }
        }
    }

    /// Whether this session says it works in `root`: its first message names the folder, or its shell cd'd into it.
    func mentions(_ root: String, home: String) -> Bool {
        func expand(_ p: String) -> String { p.hasPrefix("~/") ? home + p.dropFirst() : p }
        func inside(_ p: String) -> Bool { let e = expand(p); return e == root || e.hasPrefix(root + "/") }
        if cdTargets.contains(where: inside) { return true }
        guard let text = firstUserText.map({ $0.replacingOccurrences(of: "~/", with: home + "/") }) else { return false }
        var from = text.startIndex
        while let r = text.range(of: root, range: from..<text.endIndex) {
            // the whole folder, not a longer name that starts with it ("pebble" is not "pebble-old")
            if r.upperBound == text.endIndex || !(text[r.upperBound].isLetter || text[r.upperBound].isNumber || "-_.".contains(text[r.upperBound])) { return true }
            from = r.upperBound
        }
        return false
    }

    // MARK: out

    /// Claude Code keeps each sub-agent next to its session: <session>/subagents/agent-*.meta.json.
    func subAgents() -> [SubAgent] {
        guard provider == .claude else { return [] }
        let dir = url.deletingPathExtension().appendingPathComponent("subagents")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasSuffix(".meta.json") }.sorted { $0.path < $1.path }.compactMap { f in
            guard let d = try? Data(contentsOf: f), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
            let id = f.lastPathComponent.replacingOccurrences(of: ".meta.json", with: "")
            return SubAgent(id: id, type: o["agentType"] as? String ?? "agent", summary: Self.short(o["description"] as? String ?? "", 60),
                            finished: o["finished"] as? Bool ?? false)
        }
    }

    func session() -> Session? {
        // a Windows folder in one spelling, so it is the same folder as the one a URL names
        guard let cwd = (startCwd ?? cwd).map(PathText.native), let last else { return nil }
        let raw = title ?? firstPrompt.map { Self.short($0, 60) } ?? ""
        let clean = raw.replacingOccurrences(of: #"[*_`#>]+"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let name = clean.isEmpty ? "\(provider.displayName) in \(PathText.name(cwd))" : clean
        // the heartbeat's own CEO run (its prompt says so): named for what it is, and it never waits for you
        let heartbeat = firstPrompt?.contains("Meatproxy's heartbeat started this run") ?? false
        var s = Session(id: id, provider: provider, cwd: cwd, title: heartbeat ? "CEO run (heartbeat)" : name, branch: branch, model: model,
                        startedAt: started, lastAt: last, turnOpen: turnOpen, activities: items, subAgents: subAgents())
        if heartbeat { s.heartbeatRun = true }
        s.lastSaid = lastSaid
        s.entrypoint = entrypoint
        return s
    }
}
