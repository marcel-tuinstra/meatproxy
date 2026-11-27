import Foundation
import FactoryCore

/// A server you set up in the app's settings: where to reach it over SSH and what it is in the Server room.
public struct ServerConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// the name on its rack and its body in Orbit
    public var name: String
    /// what `ssh` connects to: a host name, `user@host`, or a Host alias from ~/.ssh/config
    public var host: String
    public var kind: ServerKind
    /// Optional: a command of your own instead of the built-in check. Exit 0 is ok, 1 a warning, anything else down;
    /// the first line it prints is the detail.
    public var check: String?
    /// alerts for this server (default on): a notification when it goes down or warns, and back up
    public var alerts: Bool?
    /// what the Server room's DevOps agent may do here on its own (default: diagnose, ask for every fix)
    public var autonomy: OpsAutonomy?
    /// public addresses served from here, checked for uptime and their TLS certificate
    public var urls: [String]?
    public init(id: String = UUID().uuidString, name: String, host: String, kind: ServerKind = .server, check: String? = nil,
                alerts: Bool? = nil, autonomy: OpsAutonomy? = nil, urls: [String]? = nil) {
        self.id = id; self.name = name; self.host = host; self.kind = kind; self.check = check
        self.alerts = alerts; self.autonomy = autonomy; self.urls = urls
    }
    public var alertsOn: Bool { alerts ?? true }
    public var opsAutonomy: OpsAutonomy { autonomy ?? .observe }
    public var siteURLs: [String] { urls ?? [] }

    /// A host ssh will take as one argument and never as an option: no leading dash, no spaces or control characters.
    public static func validHost(_ h: String) -> Bool {
        let t = h.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && !t.hasPrefix("-") && t.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
    }
}

/// Where the app keeps its settings: ~/Library/Application Support/Meatproxy. Before the brand (D45) the folder was called
/// "Software Factory"; the first start after that moves it over, so no server or factory is lost.
/// The environment for the processes the app starts (ssh, a CEO run): ours, with an ssh-agent that actually holds your
/// keys. An app started from the Finder, a launch agent or a script gets the login session's agent from launchd, which
/// may be empty while your keys live in another agent (OpenSSH keeps its sockets in ~/.ssh/agent). Without a key, ssh
/// says "Permission denied (publickey)" although the same login works in Terminal.
public enum UserEnvironment {
    public static func withSSHAgent(_ env: [String: String] = ProcessInfo.processInfo.environment,
                                    agent: () -> String? = { sshAgent }) -> [String: String] {
        var env = env
        if let sock = agent(), !sock.isEmpty { env["SSH_AUTH_SOCK"] = sock }
        return env
    }

    /// The first agent with keys: our own SSH_AUTH_SOCK, launchd's, then the newest sockets in ~/.ssh/agent. If none
    /// has keys, our own (or launchd's), so ssh behaves as it would have. Asked once.
    public static let sshAgent: String? = {
        let own = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"].flatMap { $0.isEmpty ? nil : $0 }
        let candidates = [own, launchdSSHAgent].compactMap { $0 } + agentSockets()
        return candidates.first(where: hasKeys) ?? own ?? launchdSSHAgent
    }()

    /// The agent sockets in ~/.ssh/agent, newest first.
    static func agentSockets(_ dir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/agent")) -> [String] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items.filter { (try? fm.attributesOfItem(atPath: $0.path)[.type] as? FileAttributeType) == .typeSocket }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }.map(\.path)
    }

    /// `ssh-add -l` against a socket: exit 0 means the agent answers and holds at least one key.
    static func hasKeys(_ sock: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Tools.ssh("ssh-add"))
        p.arguments = ["-l"]
        p.environment = ["SSH_AUTH_SOCK": sock, "HOME": NSHomeDirectory()]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try Processes.start(p) } catch { return false }
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning { p.terminate(); return false }
        return p.terminationStatus == 0
    }

    /// `launchctl getenv SSH_AUTH_SOCK`: the agent macOS starts for your login session. Only a Mac has launchd.
    static var launchdSSHAgent: String? {
        #if !os(macOS)
        return nil
        #else
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["getenv", "SSH_AUTH_SOCK"]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
        #endif
    }
}

/// What the Server room's DevOps agent may do on a server without asking you, set per server.
public enum OpsAutonomy: String, Codable, Sendable, CaseIterable {
    /// the agent leaves this server alone
    case off
    /// it reads and diagnoses; every repair is a yes/no question to you
    case observe
    /// it does the safe repairs itself (restart a known service, prune old images and logs) and reports them; the rest asks
    case safeFixes
    public var label: String {
        switch self { case .off: "Leave alone"; case .observe: "Diagnose, ask"; case .safeFixes: "Safe fixes" }
    }
    public var explanation: String {
        switch self {
        case .off: "The DevOps agent does not touch this server. Alerts still reach you."
        case .observe: "The DevOps agent reads and diagnoses. Every repair is a yes/no question to you."
        case .safeFixes: "The DevOps agent restarts a known service or prunes old images and logs itself and reports it; anything else asks you first."
        }
    }
}

public enum AppSupport {
    public static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }
    public static var folder: URL { base.appendingPathComponent("Meatproxy") }

    /// Moves the old "Software Factory" folder to "Meatproxy" when only the old one exists. Returns whether it moved.
    @discardableResult
    public static func migrateLegacyFolder(in base: URL = AppSupport.base) -> Bool {
        let fm = FileManager.default
        let old = base.appendingPathComponent("Software Factory"), new = base.appendingPathComponent("Meatproxy")
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return false }
        do { try fm.moveItem(at: old, to: new); return true }
        catch { NSLog("Meatproxy: could not move the settings folder to %@: %@", new.path, error.localizedDescription); return false }
    }
}

/// The servers set up on this Mac, in ~/Library/Application Support/Meatproxy/servers.json. Host names only: no
/// passwords or keys (the app uses your SSH keys and agent).
public struct ServerSettingsStore: Sendable {
    public let url: URL
    public init(url: URL = ServerSettingsStore.defaultURL) { self.url = url }

    public static var defaultURL: URL { AppSupport.folder.appendingPathComponent("servers.json") }

    private struct File: Codable { var servers: [ServerConfig] }

    /// When the file last changed (nil: there is none), so the app picks up an edit made outside it.
    public var modified: Date? { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }

    public func load() -> [ServerConfig] {
        guard let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return f.servers
    }

    public func save(_ servers: [ServerConfig]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(File(servers: servers)).write(wholeTo: url)
    }
}

/// Checks a server over SSH, the way you would from Terminal, with your keys and your ~/.ssh/config, but never
/// interactively: BatchMode, so a server that wants a password (or a key whose passphrase is not in the agent or the
/// keychain) fails at once instead of asking. Host keys are checked as always: an unknown or changed one fails too.
/// The built-in check only reads: load, cores, the root disk and memory.
public enum ServerProbe {
    /// The result of one check.
    public struct Result: Sendable, Equatable {
        public var state: ServerState
        public var detail: String
        /// the check could not log in without a password: the settings say how to fix that
        public var needsKey: Bool = false
        /// ssh got in (password-free) and ran the check, whatever the check said
        public var reached: Bool = true
        /// the numbers the built-in check read
        public var metrics: ServerMetrics?
        public init(state: ServerState, detail: String, needsKey: Bool = false, reached: Bool = true, metrics: ServerMetrics? = nil) {
            self.state = state; self.detail = detail; self.needsKey = needsKey; self.reached = reached; self.metrics = metrics
        }
    }

    /// What ran: its exit status, what it printed, and whether it was stopped for taking too long.
    public struct Output: Sendable {
        public var status: Int32, stdout: String, stderr: String, timedOut: Bool
        public init(status: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
            self.status = status; self.stdout = stdout; self.stderr = stderr; self.timedOut = timedOut
        }
    }

    /// Runs ssh with these arguments (a seam for tests).
    public typealias Runner = @Sendable (_ arguments: [String], _ timeout: TimeInterval) -> Output

    /// The built-in check, POSIX sh: Linux first, with fallbacks for macOS and BSD. Each line starts with a key.
    public static let builtInCheck = """
    echo "cores $(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"; \
    echo "load $(cut -d' ' -f1 /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')"; \
    echo "disk $(df -P / 2>/dev/null | awk 'NR==2 {print $5}')"; \
    df -Pk / 2>/dev/null | awk 'NR==2 {print "diskkb", $2, $3}'; \
    free -b 2>/dev/null | awk '/^Mem:/ {print "mem", $2, $7}'
    """

    public static func arguments(for server: ServerConfig) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1",
         "-T", "--", server.host.trimmingCharacters(in: .whitespaces), server.check?.isEmpty == false ? server.check! : builtInCheck]
    }

    public static func check(_ server: ServerConfig, timeout: TimeInterval = 15, run: Runner = ServerProbe.run) -> Result {
        guard ServerConfig.validHost(server.host) else { return Result(state: .down, detail: "not a host name", reached: false) }
        let out = run(arguments(for: server), timeout)
        if out.timedOut { return Result(state: .down, detail: "no answer within \(Int(timeout)) s", reached: false) }
        // 255 is ssh's own failure: it never got to run the check
        if out.status == 255 { return failure(out.stderr) }
        if let custom = server.check, !custom.isEmpty {
            let line = out.stdout.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
            switch out.status {
            case 0: return Result(state: .ok, detail: line ?? "check passed")
            case 1: return Result(state: .warn, detail: line ?? "check warned")
            default: return Result(state: .down, detail: line ?? "check failed (exit \(out.status))")
            }
        }
        return out.status == 0 || !out.stdout.isEmpty ? health(out.stdout) : Result(state: .down, detail: "check failed (exit \(out.status))")
    }

    /// Why ssh could not get in, in words you can act on.
    public static func failure(_ stderr: String) -> Result {
        let e = stderr.lowercased()
        if e.contains("host key verification failed") || e.contains("remote host identification has changed") {
            return Result(state: .down, detail: "host key unknown or changed: connect once with ssh in Terminal to check it", reached: false)
        }
        if e.contains("permission denied") || e.contains("too many authentication failures") {
            return Result(state: .down, detail: "no password-free login: add your SSH key to the server, or load it with ssh-add", needsKey: true, reached: false)
        }
        if e.contains("could not resolve hostname") { return Result(state: .down, detail: "host name not found", reached: false) }
        if e.contains("timed out") { return Result(state: .down, detail: "no connection: timed out", reached: false) }
        if e.contains("connection refused") { return Result(state: .down, detail: "no connection: refused", reached: false) }
        if e.contains("no route to host") || e.contains("network is unreachable") { return Result(state: .down, detail: "no connection: unreachable", reached: false) }
        let last = stderr.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return Result(state: .down, detail: last.isEmpty ? "no connection" : String(last.prefix(120)), reached: false)
    }

    /// Warning thresholds: the root disk this full, the 1-minute load this high per core, this little memory free.
    public static let diskWarn = 90, loadWarn = 1.5, memoryFreeWarn = 0.1

    /// Reads the built-in check's lines ("cores 4", "load 0.52", "disk 61%", "mem <total> <available>").
    public static func health(_ text: String) -> Result {
        var cores: Double?, load: Double?, disk: Int?, memUsed: Double?
        var diskTotal: Double?, diskUsed: Double?, memTotal: Double?, memAvailable: Double?
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: " ").map(String.init)
            guard f.count >= 2 else { continue }
            switch f[0] {
            case "cores": cores = Double(f[1])
            case "load": load = Double(f[1].replacingOccurrences(of: ",", with: "."))
            case "disk": disk = Int(f[1].trimmingCharacters(in: CharacterSet(charactersIn: "%")))
            case "mem": if f.count >= 3, let t = Double(f[1]), let a = Double(f[2]), t > 0 { memUsed = 1 - a / t; memTotal = t; memAvailable = a }
            case "diskkb": if f.count >= 3, let t = Double(f[1]), let u = Double(f[2]) { diskTotal = t * 1024; diskUsed = u * 1024 }
            default: break
            }
        }
        var parts: [String] = [], warnings: [String] = []
        if let load {
            parts.append(String(format: "load %.2f", load))
            if let cores, cores > 0, load / cores >= loadWarn { warnings.append(String(format: "load %.1f on %d cores", load, Int(cores))) }
        }
        if let disk {
            parts.append("disk \(disk)%")
            if disk >= diskWarn { warnings.append("disk \(disk)% full") }
        }
        if let memUsed {
            parts.append("memory \(Int((memUsed * 100).rounded()))%")
            if 1 - memUsed < memoryFreeWarn { warnings.append("memory \(Int((memUsed * 100).rounded()))% used") }
        }
        var m = ServerMetrics(load: load, cores: cores.map { Int($0) }, disk: disk, memory: memUsed.map { Int(($0 * 100).rounded()) })
        m.diskUsedBytes = diskUsed; m.diskTotalBytes = diskTotal
        if let t = memTotal, let a = memAvailable { m.memoryUsedBytes = t - a; m.memoryTotalBytes = t }
        if !warnings.isEmpty { return Result(state: .warn, detail: warnings.joined(separator: " · "), metrics: m) }
        return Result(state: .ok, detail: parts.isEmpty ? "reachable" : parts.joined(separator: " · "), metrics: m)
    }

    /// Runs the system's ssh, with nothing on stdin, stopped after `timeout`.
    public static let run: Runner = { arguments, timeout in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Tools.ssh())
        p.arguments = arguments
        p.environment = UserEnvironment.withSSHAgent()
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try Processes.start(p) } catch { return Output(status: -1, stdout: "", stderr: error.localizedDescription) }
        // read both pipes while it runs, so a chatty server cannot fill a pipe and stall it
        let group = DispatchGroup()
        nonisolated(unsafe) var o = Data(), e = Data()
        group.enter(); DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut { timedOut = true; p.terminate(); done.wait() }
        group.wait()
        return Output(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self), timedOut: timedOut)
    }
}

/// Checks every server set up, now and then, on a background queue, and keeps the last result of each.
public final class ServerMonitor: @unchecked Sendable {
    public private(set) var configs: [ServerConfig]
    private var results: [String: (ServerProbe.Result, Date)] = [:]
    private let lock = NSLock()
    private let run: ServerProbe.Runner
    private var checking = false

    public init(configs: [ServerConfig], run: @escaping ServerProbe.Runner = ServerProbe.run) {
        self.configs = configs; self.run = run
    }

    /// The servers for the world: every one set up that has been checked at least once (a state is never guessed).
    public var servers: [Server] {
        lock.lock(); defer { lock.unlock() }
        return configs.compactMap { c in
            results[c.id].map { r in Server(id: c.id, name: c.name, kind: c.kind, state: r.0.state, detail: r.0.detail, checkedAt: r.1, metrics: r.0.metrics) }
        }
    }

    public func result(_ id: String) -> ServerProbe.Result? { lock.lock(); defer { lock.unlock() }; return results[id]?.0 }

    public func update(_ configs: [ServerConfig]) {
        lock.lock(); self.configs = configs
        let ids = Set(configs.map(\.id)); results = results.filter { ids.contains($0.key) }
        lock.unlock()
    }

    /// Checks all servers at once (each with its own ssh), then calls `done` on the main queue.
    public func checkAll(done: @escaping @Sendable () -> Void = {}) {
        lock.lock()
        if checking { lock.unlock(); return }
        checking = true
        let list = configs
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            DispatchQueue.concurrentPerform(iterations: list.count) { k in
                let r = ServerProbe.check(list[k], run: self.run)
                self.lock.lock(); self.results[list[k].id] = (r, Date()); self.lock.unlock()
            }
            self.lock.lock(); self.checking = false; self.lock.unlock()
            DispatchQueue.main.async { done() }
        }
    }
}

/// The Host aliases in an ssh config, for adding servers in one go: in file order, once each, without patterns
/// (`*`, `?`) or negations, and without `Match` blocks. `Include` is not followed.
public enum SSHHosts {
    public static func aliases(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = (raw.components(separatedBy: "#").first ?? "").trimmingCharacters(in: .whitespaces)
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard words.count > 1, words[0].lowercased() == "host" else { continue }
            for w in words.dropFirst() where !w.contains("*") && !w.contains("?") && !w.hasPrefix("!") && !out.contains(w) { out.append(w) }
        }
        return out
    }
    /// ~/.ssh/config's aliases, or none when there is no such file.
    public static func fromUserConfig() -> [String] {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        return aliases((try? String(contentsOf: u, encoding: .utf8)) ?? "")
    }
}
