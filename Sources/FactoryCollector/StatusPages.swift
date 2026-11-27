import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FactoryCore

/// The status pages you watch (D69): the providers your factories run on, GitHub, and any of your own. Kept in
/// Application Support as status-sources.json; no tokens, these pages are public.
public struct StatusSource: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// the page's Statuspage JSON (…/api/v2/status.json)
    public var url: String
    /// the page people open
    public var page: String
    /// claude or codex: factories on that runtime wait while it is down
    public var runtime: String?
    public var on: Bool
    public init(id: String, name: String, url: String, page: String, runtime: String? = nil, on: Bool = true) {
        self.id = id; self.name = name; self.url = url; self.page = page; self.runtime = runtime; self.on = on
    }

    public static let defaults: [StatusSource] = [
        StatusSource(id: "claude", name: "Claude", url: "https://status.claude.com/api/v2/status.json", page: "https://status.claude.com", runtime: "claude"),
        StatusSource(id: "openai", name: "OpenAI", url: "https://status.openai.com/api/v2/status.json", page: "https://status.openai.com", runtime: "codex"),
        StatusSource(id: "github", name: "GitHub", url: "https://www.githubstatus.com/api/v2/status.json", page: "https://www.githubstatus.com"),
    ]

    /// A source from a status page address you type: its base, with the Statuspage JSON path added.
    public static func custom(_ address: String) -> StatusSource? {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("http") { s = "https://" + s }
        guard let u = URL(string: s), u.scheme == "https", let host = u.host, host.contains(".") else { return nil }
        let base = "https://\(host)"
        return StatusSource(id: host, name: host, url: base + "/api/v2/status.json", page: base)
    }
}

public enum StatusSourcesStore {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Meatproxy/status-sources.json")
    }
    public static func load() -> [StatusSource] {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode([StatusSource].self, from: d) else { return StatusSource.defaults }
        return s
    }
    public static func save(_ s: [StatusSource]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(s).write(wholeTo: url)
    }
}

/// Reads the status pages every five minutes (off the main queue) and keeps what they said. A page that could not be
/// read keeps its last answer and turns unknown once that is 15 minutes old.
public final class StatusPages: @unchecked Sendable {
    public static let interval: TimeInterval = 300
    private let transport: HTTPTransport
    private let lock = NSLock()
    private var last: [String: ServiceStatus] = [:]
    private var sources: [StatusSource] = StatusSource.defaults

    public init(transport: @escaping HTTPTransport = WakeSources.systemTransport) { self.transport = transport }

    /// What the watched pages said, in the order of your list.
    public func current() -> [ServiceStatus] {
        lock.lock(); defer { lock.unlock() }
        return sources.filter(\.on).map { s in
            last[s.id] ?? ServiceStatus(id: s.id, name: s.name, page: s.page, state: .unknown, checkedAt: nil, runtime: s.runtime)
        }
    }

    /// Reads each page. Blocking.
    public func update(_ list: [StatusSource], now: Date = Date()) {
        lock.lock(); sources = list; lock.unlock()
        for s in list where s.on {
            guard let u = URL(string: s.url) else { continue }
            var r = URLRequest(url: u, timeoutInterval: 10)
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, code, _) = transport(r), code == 200, let (state, detail) = Self.parse(data) else { continue }
            let st = ServiceStatus(id: s.id, name: s.name, page: s.page, state: state, detail: detail, checkedAt: now, runtime: s.runtime)
            lock.lock(); last[s.id] = st; lock.unlock()
        }
    }

    /// A Statuspage answer: none is ok, minor degraded, major and critical down.
    static func parse(_ data: Data) -> (ServiceStatus.State, String)? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let st = o["status"] as? [String: Any],
              let ind = st["indicator"] as? String else { return nil }
        let detail = st["description"] as? String ?? ""
        switch ind {
        case "none": return (.ok, detail)
        case "minor", "maintenance": return (.degraded, detail)
        case "major", "critical": return (.down, detail)
        default: return (.unknown, detail)
        }
    }

    /// The name of the provider a runtime runs on when its page says it is down now.
    public func down(_ runtime: String, now: Date = Date()) -> String? {
        current().first { $0.runtime == runtime && $0.shown(now: now) == .down }?.name
    }
}
