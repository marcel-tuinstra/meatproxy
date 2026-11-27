import Foundation
import FactoryCore

/// What every session would have cost at API prices (D61), per day and per folder it ran in. It reads the session files of
/// Claude Code and Codex (the last 35 days) once in full and after that only what was appended, and keeps per-day totals
/// in Application Support, so a restart does not read gigabytes again. Read-only on the session files; it stores sums, no
/// content.
public final class CostLedger: @unchecked Sendable {
    public struct Day: Codable, Equatable, Sendable {
        public var usd: Double = 0
        public var tokens: Int = 0
        public var unpricedTokens: Int = 0
    }

    struct FileState: Codable {
        var offset: UInt64 = 0
        var size: UInt64 = 0
        var codex = false
        /// the folder the session started in (where it counts)
        var cwd: String?
        /// Codex: the model in use and the running totals the last token count gave (a count can repeat)
        var model: String?
        var totals: [String: Int] = [:]
        /// Claude: one API message is written as several lines with the same id and usage; count it once
        var lastID: String?
        var days: [String: Day] = [:]
    }

    static let keepDays = 35
    static let version = 1

    private let home: URL
    private let store: URL?
    private let lock = NSLock()
    private var files: [String: FileState] = [:]

    /// `store`: where the sums are kept between runs (nil: in memory only, for tests)
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, store: URL? = CostLedger.defaultStore) {
        self.home = home
        self.store = store
        if let store, let data = try? Data(contentsOf: store),
           let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == Self.version {
            files = saved.files
        }
    }

    public static var defaultStore: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Meatproxy/cost-ledger.json")
    }

    private struct Saved: Codable { var version: Int; var files: [String: FileState] }

    // MARK: reading

    /// Reads what was appended to every session file of the last 35 days. Slow the first time; call it off the main queue.
    public func update(now: Date = Date()) {
        let list = sessionFiles(now: now)
        var next: [String: FileState] = [:]
        lock.lock(); let known = files; lock.unlock()
        for (url, codex) in list {
            var st = known[url.path] ?? FileState(codex: codex)
            read(url, into: &st)
            next[url.path] = st
        }
        // forget days (and files) older than the window
        let oldest = Self.dayKey(now.addingTimeInterval(-Double(Self.keepDays) * 86_400))
        for (k, st) in next { next[k]?.days = st.days.filter { $0.key >= oldest } }
        lock.lock(); files = next; lock.unlock()
        save()
    }

    private func save() {
        guard let store else { return }
        lock.lock(); let snapshot = Saved(version: Self.version, files: files); lock.unlock()
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(wholeTo: store) }
    }

    func read(_ url: URL, into st: inout FileState) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if size < st.offset { st = FileState(codex: st.codex) }   // rewritten: start over
        st.size = size
        guard size > st.offset, let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: st.offset)
        // in pieces of 8 MB, so a big file never sits in memory whole
        var carry = Data()
        while let piece = try? fh.read(upToCount: 8 << 20), !piece.isEmpty {
            var data = carry; data.append(piece)
            guard let end = data.lastIndex(of: 10) else { carry = data; continue }
            for line in data[data.startIndex..<end].split(separator: 10, omittingEmptySubsequences: true) {
                if st.codex { codexLine(Data(line), &st) } else { claudeLine(Data(line), &st) }
            }
            st.offset += UInt64(end - data.startIndex + 1)
            carry = Data(data[(end + 1)...])
        }
    }

    private static let usageMark = Data("\"usage\"".utf8), cwdMark = Data("\"cwd\"".utf8)
    private static let tokenMark = Data("token_count".utf8), contextMark = Data("turn_context".utf8), metaMark = Data("session_meta".utf8)

    func claudeLine(_ line: Data, _ st: inout FileState) {
        let hasUsage = line.range(of: Self.usageMark) != nil
        guard hasUsage || (st.cwd == nil && line.range(of: Self.cwdMark) != nil),
              let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if st.cwd == nil, let c = o["cwd"] as? String, !c.isEmpty { st.cwd = c }
        guard o["type"] as? String == "assistant", let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any],
              let model = m["model"] as? String, model != "<synthetic>" else { return }
        let id = m["id"] as? String
        if let id, id == st.lastID { return }
        st.lastID = id
        func n(_ k: String, _ d: [String: Any]? = nil) -> Int { ((d ?? u)[k] as? NSNumber)?.intValue ?? 0 }
        let write = n("cache_creation_input_tokens"), split = u["cache_creation"] as? [String: Any]
        let long = split.map { n("ephemeral_1h_input_tokens", $0) } ?? 0
        let usage = TokenUsage(input: n("input_tokens"), cacheWriteShort: max(0, write - long), cacheWriteLong: long,
                               cacheRead: n("cache_read_input_tokens"), output: n("output_tokens"), fast: u["speed"] as? String == "fast")
        add(usage, model: model, at: o["timestamp"], &st)
    }

    func codexLine(_ line: Data, _ st: inout FileState) {
        let token = line.range(of: Self.tokenMark) != nil, context = line.range(of: Self.contextMark) != nil
        let meta = st.cwd == nil && line.range(of: Self.metaMark) != nil
        guard token || context || meta, let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let p = o["payload"] as? [String: Any] else { return }
        let type = o["type"] as? String
        if type == "session_meta" || type == "turn_context" {
            if st.cwd == nil, let c = p["cwd"] as? String, !c.isEmpty { st.cwd = c }
            if let m = p["model"] as? String { st.model = m }
            return
        }
        guard p["type"] as? String == "token_count", let info = p["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any] else { return }
        // the running totals, so a count that repeats adds nothing
        func t(_ k: String) -> Int { (total[k] as? NSNumber)?.intValue ?? 0 }
        let keys = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens"]
        var delta: [String: Int] = [:]
        for k in keys { delta[k] = max(0, t(k) - (st.totals[k] ?? 0)) }
        guard delta.values.contains(where: { $0 > 0 }) else { return }
        for k in keys { st.totals[k] = t(k) }
        let cached = delta["cached_input_tokens"]!, written = delta["cache_write_input_tokens"]!
        // long context is per request: the last request's prompt says which rate applies
        let lastPrompt = ((info["last_token_usage"] as? [String: Any])?["input_tokens"] as? NSNumber)?.intValue ?? 0
        let usage = TokenUsage(input: max(0, delta["input_tokens"]! - cached - written), cacheWriteShort: written,
                               cacheRead: cached, output: delta["output_tokens"]!)
        add(usage, model: st.model ?? "", prompt: lastPrompt, at: o["timestamp"], &st)
    }

    /// `prompt`: the request's whole prompt when `u` is only part of it (Codex), for the long-context rate
    private func add(_ u: TokenUsage, model: String, prompt: Int? = nil, at: Any?, _ st: inout FileState) {
        if let usd = ApiPrices.cost(model: model, u, prompt: prompt) { record(usd, tokens: u.total, at: at, &st) }
        else {
            let k = Self.dayKey(Self.date(at) ?? Date())
            st.days[k, default: Day()].unpricedTokens += u.total
            st.days[k, default: Day()].tokens += u.total
        }
    }

    private func record(_ usd: Double, tokens: Int, at: Any?, _ st: inout FileState) {
        let k = Self.dayKey(Self.date(at) ?? Date())
        st.days[k, default: Day()].usd += usd
        st.days[k, default: Day()].tokens += tokens
    }

    // MARK: answers

    /// Per floor: what its sessions cost, today, the last 7 days and the last 30. `key` maps the folder a session ran in,
    /// and whether it is a Codex session, to its floor (the collector uses the project's id).
    public func costs(now: Date = Date(), key: (_ cwd: String, _ codex: Bool) -> String) -> [String: ProjectCost] {
        lock.lock(); let snapshot = files; lock.unlock()
        let today = Self.dayKey(now), week = Self.dayKey(now.addingTimeInterval(-6 * 86_400)), month = Self.dayKey(now.addingTimeInterval(-29 * 86_400))
        var out: [String: ProjectCost] = [:]
        for st in snapshot.values {
            guard let cwd = st.cwd else { continue }
            let root = key(cwd, st.codex)
            var c = out[root] ?? ProjectCost()
            for (k, d) in st.days where k >= month {
                c.month += d.usd; c.unpricedTokens += d.unpricedTokens
                if k >= week { c.week += d.usd }
                if k == today { c.today += d.usd }
            }
            out[root] = c
        }
        return out
    }

    // MARK: files

    func sessionFiles(now: Date) -> [(URL, Bool)] {
        let fm = FileManager.default
        let window = Double(Self.keepDays) * 86_400
        func recent(_ u: URL) -> Bool {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return d.map { now.timeIntervalSince($0) < window } ?? false
        }
        func children(_ u: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        var out: [(URL, Bool)] = []
        // Claude Code: a session per file, and its sub-agents in <session>/subagents/
        for dir in children(home.appendingPathComponent(".claude/projects")) {
            for f in children(dir) {
                if f.pathExtension == "jsonl" { if recent(f) { out.append((f, false)) } }
                else { for s in children(f.appendingPathComponent("subagents")) where s.pathExtension == "jsonl" && recent(s) { out.append((s, false)) } }
            }
        }
        // Codex: sessions/<year>/<month>/<day>/rollout-*.jsonl
        for y in children(home.appendingPathComponent(".codex/sessions")) {
            for m in children(y) { for d in children(m) {
                for f in children(d) where f.lastPathComponent.hasPrefix("rollout-") && f.pathExtension == "jsonl" && recent(f) { out.append((f, true)) }
            } }
        }
        return out
    }

    nonisolated(unsafe) private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    nonisolated(unsafe) private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    /// the local calendar day, "2026-11-16"
    static func dayKey(_ d: Date) -> String { dayFormat.string(from: d) }

    static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return isoFraction.date(from: s) ?? iso.date(from: s)
    }
}
