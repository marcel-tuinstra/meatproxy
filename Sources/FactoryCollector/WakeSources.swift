import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif
import FactoryCore

/// Your tokens for the wake-up sources (D61), in the macOS Keychain: never in a file, a log or the repo.
/// Linux and Windows have no Keychain: there a token comes from the environment (`MEATPROXY_SENTRY_TOKEN`,
/// `MEATPROXY_TRACKER_TOKEN`) and Meatproxy saves none.
public enum Secrets {
    public enum Key: String, CaseIterable, Sendable {
        case sentry = "sentry-token", tracker = "tracker-token"
        public var label: String { self == .sentry ? "Sentry" : "Tracker" }
        /// the variable that holds this token where there is no Keychain
        public var variable: String { self == .sentry ? "MEATPROXY_SENTRY_TOKEN" : "MEATPROXY_TRACKER_TOKEN" }
    }
    static let service = "dev.tuinstra.meatproxy"

    /// A token from the environment: nil when the variable is missing or empty.
    static func fromEnvironment(_ k: Key, _ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let v = environment[k.variable]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }

    #if canImport(Security)
    public static func get(_ k: Key) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: k.rawValue, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Saves a token (nil or empty: removes it). Returns whether the Keychain took it.
    @discardableResult
    public static func set(_ k: Key, _ value: String?) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: k.rawValue]
        SecItemDelete(base as CFDictionary)
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return true }
        var add = base; add[kSecValueData as String] = Data(v.utf8); add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
    #else
    public static func get(_ k: Key) -> String? { fromEnvironment(k) }

    /// There is nowhere safe to keep a token here yet, so nothing is saved: false, unless there was nothing to save.
    @discardableResult
    public static func set(_ k: Key, _ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
    #endif
}

/// One HTTP exchange, so tests can answer for the network: the body and status, or nil when it failed.
public typealias HTTPTransport = @Sendable (URLRequest) -> (Data, Int, [String: String])?

/// The wake-up sources (D61): every 15 minutes Meatproxy asks each factory's Sentry project for new or returning errors
/// and its Tracker project for stories that changed, and wakes the CEO with their ids and titles. The first look only
/// notes what is there. It reads, never writes, and uses your own tokens.
public final class WakeSources: @unchecked Sendable {
    public static let interval: TimeInterval = 15 * 60

    private let transport: HTTPTransport
    private let lock = NSLock()
    /// per factory: the Sentry issues seen and how they stood ("id" → substatus), the Tracker stories and their state
    private var sentrySeen: [String: [String: String]] = [:]
    private var trackerSeen: [String: [String: String]] = [:]
    private var healthByRoot: [String: FactoryHealth] = [:]
    /// How each factory's sources did at their last check (Settings and the floor show it; a new failure notifies).
    public var health: [String: FactoryHealth] { lock.lock(); defer { lock.unlock() }; return healthByRoot }
    private func note(_ root: String, _ source: WritableKeyPath<FactoryHealth, SourceHealth?>, ok: Bool, _ line: String, _ now: Date) {
        lock.lock(); defer { lock.unlock() }
        let was = healthByRoot[root]?[keyPath: source]
        let since: Date? = ok ? nil : (was.flatMap { $0.ok ? nil : $0.since } ?? now)
        healthByRoot[root, default: FactoryHealth()][keyPath: source] = SourceHealth(ok: ok, line: line, at: now, since: since)
    }

    /// Tracker's MCP address as typed in Settings: https only; nil (Tracker off) for anything else.
    public static func trackerURL(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), u.scheme == "https", u.host?.isEmpty == false else { return nil }
        return u
    }

    public init(transport: @escaping HTTPTransport = WakeSources.systemTransport) { self.transport = transport }

    /// What wakes which factory now. `factories`: each factory's folder, its sources, its heartbeat and whether its
    /// mandate allows bug work (bugs: off means no Sentry wake). Blocking: call it off the main queue.
    public func check(_ factories: [(root: String, sources: FactorySources, heartbeat: Heartbeat, bugsAllowed: Bool)],
                      tokens: (sentry: String?, tracker: String?), trackerURL: URL? = nil, now: Date = Date()) -> [(String, WakeReason)] {
        var wakes: [(String, WakeReason)] = []
        for f in factories where !f.heartbeat.paused {
            if f.heartbeat.wakeOnSentry, f.bugsAllowed, f.sources.hasSentry, let t = tokens.sentry,
               let found = sentry(f.root, f.sources, token: t, now: now), !found.isEmpty {
                wakes.append((f.root, .sentry(found)))
            }
            if f.heartbeat.wakeOnTracker, let slug = f.sources.tracker, let t = tokens.tracker, let url = trackerURL,
               let found = tracker(f.root, slug: slug, token: t, url: url, now: now), !found.isEmpty {
                wakes.append((f.root, .tracker(found)))
            }
        }
        return wakes
    }

    // MARK: Sentry

    /// New errors (an id not seen before) and returning ones (now regressed or escalating), as "APP-12: title".
    func sentry(_ root: String, _ s: FactorySources, token: String, now at: Date = Date()) -> [String]? {
        guard let org = s.sentryOrg, let project = s.sentryProject,
              var c = URLComponents(string: "https://\(s.sentryHost)/api/0/projects/\(org)/\(project)/issues/") else { return nil }
        c.queryItems = [.init(name: "query", value: "is:unresolved level:[error,fatal]"), .init(name: "statsPeriod", value: "14d"),
                        .init(name: "sort", value: "date"), .init(name: "limit", value: "50")]
        guard let url = c.url else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, status, _) = transport(r) else { note(root, \.sentry, ok: false, "Sentry did not answer", at); return nil }
        guard status == 200 else { note(root, \.sentry, ok: false, Self.reason(status), at); return nil }
        guard let issues = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            note(root, \.sentry, ok: false, "Sentry's answer was not a list of issues", at); return nil
        }
        note(root, \.sentry, ok: true, "Works", at)
        var now: [String: String] = [:], names: [String: String] = [:]
        for i in issues {
            guard let id = i["id"] as? String else { continue }
            now[id] = (i["substatus"] as? String) ?? "ongoing"
            names[id] = "\(i["shortId"] as? String ?? id): \((i["title"] as? String ?? "").prefix(80))"
        }
        lock.lock(); let before = sentrySeen[root]; sentrySeen[root] = (before ?? [:]).merging(now) { _, n in n }; lock.unlock()
        guard let before else { return [] }   // the first look only notes
        let returning: Set<String> = ["regressed", "escalating"]
        return now.keys.sorted().filter { id in
            guard let was = before[id] else { return true }
            return returning.contains(now[id]!) && !returning.contains(was)
        }.compactMap { names[$0] }
    }

    // MARK: Tracker

    /// Stories that became rejected, or newly ready to pick up (unstarted), as "NTF-3 rejected: title".
    func tracker(_ root: String, slug: String, token: String, url: URL, now at: Date = Date()) -> [String]? {
        let mcp = MCPClient(url: url, token: token, transport: transport)
        var now: [String: String] = [:], names: [String: String] = [:]
        for state in ["rejected", "unstarted"] {
            let result: [String: Any]
            switch mcp.call("list_stories", ["project": slug, "state": state, "limit": 50]) {
            case .success(let r): result = r
            case .failure(.refused(let why)): note(root, \.tracker, ok: false, "\(slug): \(why)", at); return nil
            case .failure(let e): note(root, \.tracker, ok: false, e.line, at); return nil
            }
            guard let items = result["items"] as? [[String: Any]] else { note(root, \.tracker, ok: false, "Tracker's answer had no stories", at); return nil }
            for s in items {
                guard let key = s["key"] as? String else { continue }
                now[key] = state
                names[key] = "\(key) \(state == "unstarted" ? "ready" : state): \((s["title"] as? String ?? "").prefix(80))"
            }
        }
        note(root, \.tracker, ok: true, "Works", at)
        lock.lock(); let before = trackerSeen[root]; trackerSeen[root] = now; lock.unlock()
        guard let before else { return [] }
        return now.keys.sorted().filter { before[$0] != now[$0] }.compactMap { names[$0] }
    }

    // MARK: testing a token

    /// Whether a token works (the Test button in Settings): one read per Sentry project the factories name, or, when
    /// none names one, Sentry's own API root. The answer is one line, and true when it worked. Blocking.
    public func testSentry(token: String, projects: [FactorySources]) -> (ok: Bool, line: String) {
        let named = projects.filter(\.hasSentry)
        if named.isEmpty {
            guard let (_, status, _) = transport(Self.request("https://sentry.io/api/0/", token: token)) else { return (false, "Sentry did not answer") }
            return status == 200 ? (true, "Token accepted. No factory names a Sentry project yet.") : (false, "Sentry: " + Self.reason(status))
        }
        var ok: [String] = []
        for s in named {
            guard let org = s.sentryOrg, let project = s.sentryProject else { continue }
            guard let (_, status, _) = transport(Self.request("https://\(s.sentryHost)/api/0/projects/\(org)/\(project)/", token: token)) else {
                return (false, "\(s.sentryHost) did not answer")
            }
            guard status == 200 else { return (false, "\(org)/\(project): " + Self.reason(status)) }
            ok.append("\(org)/\(project)")
        }
        return (true, "Works: reads " + ok.joined(separator: ", "))
    }

    /// Whether a Tracker token works: one small read of each project the factories name, or a hello when none does.
    public func testTracker(token: String, slugs: [String], url: URL?) -> (ok: Bool, line: String) {
        guard let url else { return (false, "Add Tracker's MCP address first") }
        let mcp = MCPClient(url: url, token: token, transport: transport)
        if slugs.isEmpty {
            if case .failure(let e) = mcp.hello() { return (false, e.line) }
            return (true, "Token accepted. No factory names a Tracker project yet.")
        }
        for slug in slugs {
            switch mcp.call("list_stories", ["project": slug, "limit": 1]) {
            case .success: continue
            case .failure(.refused(let why)): return (false, "\(slug): \(why)")
            case .failure(let e): return (false, e.line)
            }
        }
        return (true, "Works: reads " + slugs.joined(separator: ", "))
    }

    static func request(_ url: String, token: String) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }
    static func reason(_ status: Int) -> String {
        switch status {
        case 401: return "the token was refused (401)"
        case 403: return "the token may not read this (403)"
        case 404: return "not found, or the token cannot see it (404)"
        default: return "answered \(status)"
        }
    }

    // MARK: network

    public static let systemTransport: HTTPTransport = { request in
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: (Data, Int, [String: String])?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let h = response as? HTTPURLResponse {
                let headers = Dictionary(uniqueKeysWithValues: h.allHeaderFields.compactMap { k, v in (k as? String).map { ($0.lowercased(), "\(v)") } })
                out = (data ?? Data(), h.statusCode, headers)
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 30)
        return out
    }
}

/// How one wake source did at its last check: whether it worked, in words, when, and since when it fails.
public struct SourceHealth: Equatable, Sendable {
    public var ok: Bool, line: String, at: Date, since: Date?
    public init(ok: Bool, line: String, at: Date, since: Date?) { self.ok = ok; self.line = line; self.at = at; self.since = since }
    /// It failed just now for the first time (worth a notification once).
    public var isNewFailure: Bool { !ok && since == at }
}
public struct FactoryHealth: Equatable, Sendable {
    public var sentry: SourceHealth?, tracker: SourceHealth?
    public init(sentry: SourceHealth? = nil, tracker: SourceHealth? = nil) { self.sentry = sentry; self.tracker = tracker }
}

/// Why an MCP exchange failed, in words for the Settings test line.
enum MCPError: Error, Equatable {
    case noAnswer, status(Int), refused(String)
    var line: String {
        switch self {
        case .noAnswer: return "Tracker did not answer"
        case .status(let s): return "Tracker: " + WakeSources.reason(s)
        case .refused(let why): return "Tracker: " + why
        }
    }
}

/// A small MCP client over streamable HTTP: initialize, then one tool call; reads a JSON or an event-stream answer.
struct MCPClient {
    let url: URL
    let token: String
    let transport: HTTPTransport

    private func post(_ body: [String: Any], session: String?) -> Result<(Any?, [String: String]), MCPError> {
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let session { r.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, status, headers) = transport(r) else { return .failure(.noAnswer) }
        guard (200..<300).contains(status) else { return .failure(.status(status)) }
        return .success((Self.message(data), headers))
    }

    /// The JSON-RPC message in an answer: the body itself, or the last `data:` line of an event stream.
    static func message(_ data: Data) -> Any? {
        if let o = try? JSONSerialization.jsonObject(with: data) { return o }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.components(separatedBy: "\n").reversed() where line.hasPrefix("data:") {
            if let o = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)) { return o }
        }
        return nil
    }

    private static let initialize: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                    "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                                               "clientInfo": ["name": "meatproxy", "version": "1"]]]

    /// The text of a JSON-RPC error or a tool's error block, short.
    private static func why(_ reply: Any?) -> String {
        let o = reply as? [String: Any]
        if let m = (o?["error"] as? [String: Any])?["message"] as? String { return String(m.prefix(140)) }
        let blocks = (o?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        if let t = blocks?.first(where: { $0["type"] as? String == "text" })?["text"] as? String { return String(t.prefix(140)) }
        return "the server gave no answer it could use"
    }

    /// Says hello (initialize): succeeds when the server takes the token.
    func hello() -> Result<Void, MCPError> {
        post(Self.initialize, session: nil).flatMap { reply, _ in
            (reply as? [String: Any])?["result"] != nil ? .success(()) : .failure(.refused(Self.why(reply)))
        }
    }

    /// Calls a tool and returns its result as JSON: the structured content, or the JSON in its first text block.
    func call(_ tool: String, _ arguments: [String: Any]) -> Result<[String: Any], MCPError> {
        let session: String?
        switch post(Self.initialize, session: nil) {
        case .failure(let e): return .failure(e)
        case .success(let (_, headers)): session = headers["mcp-session-id"]
        }
        _ = post(["jsonrpc": "2.0", "method": "notifications/initialized"], session: session)
        let reply: Any?
        switch post(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": tool, "arguments": arguments]], session: session) {
        case .failure(let e): return .failure(e)
        case .success(let (r, _)): reply = r
        }
        guard let result = (reply as? [String: Any])?["result"] as? [String: Any], result["isError"] as? Bool != true else {
            return .failure(.refused(Self.why(reply)))
        }
        if let s = result["structuredContent"] as? [String: Any] { return .success(s) }
        if let text = ((result["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" })?["text"] as? String,
           let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
            return .success(o)
        }
        return .failure(.refused("the answer was not JSON"))
    }
}
