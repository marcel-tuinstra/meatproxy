import Foundation
import FactoryCore

/// Runs a factory's CEO headless (D47): `claude -p` (or `codex exec`) in the project folder, with the project's own
/// permission allowlist (`.claude/settings.json`) and edits accepted, so nothing outside the allowlist can happen. One
/// run per factory at a time (a lock file, also against the launch agent), at most 45 minutes, its output in a log and
/// its outcome in a small state file under ~/Library/Application Support/Meatproxy/heartbeats. Never in the repo.
public final class HeartbeatRunner: @unchecked Sendable {
    public static let timeout: TimeInterval = 45 * 60

    /// how to start a runtime: its executable and arguments for a prompt (tests swap this)
    public struct Launch: Sendable {
        public var executable: URL
        public var arguments: [String]
        public init(executable: URL, arguments: [String]) { self.executable = executable; self.arguments = arguments }
    }
    /// what to start: the runtime, the prompt, the turn cap and the project's allowlist (its .claude/settings.json)
    public struct Request: Sendable {
        public var runtime: Heartbeat.Runtime
        public var prompt: String
        public var maxTurns: Int
        public var settings: URL?
        /// the run needs the network from inside the runtime's sandbox (the DevOps agent's ops tool)
        public var network = false
        /// the model and effort for this run (D70); nil: the runtime's default
        public var model: String? = nil
        public var effort: String? = nil
    }
    public typealias Resolve = @Sendable (Request) -> Launch?

    let folder: URL
    let resolve: Resolve
    /// the folder a run works in: the project's own (the demo swaps it for a folder that exists)
    let directory: @Sendable (String) -> URL
    private let lock = NSLock()
    private var running: [String: Process] = [:]
    /// why a run was stopped from outside (you took over), so its end says so
    private var stopReason: [String: String] = [:]

    public init(folder: URL = AppSupport.folder.appendingPathComponent("heartbeats"), resolve: @escaping Resolve = HeartbeatRunner.systemLaunch,
                directory: @escaping @Sendable (String) -> URL = { URL(fileURLWithPath: $0) }) {
        self.folder = folder
        self.resolve = resolve
        self.directory = directory
    }

    // MARK: the runtimes

    /// The real CLIs: `claude -p … --permission-mode acceptEdits` or `codex exec -s workspace-write …`, found where Homebrew
    /// or the installers put them (an app started from the Finder has no shell PATH).
    /// The project's allowlist is passed with --settings: Claude Code ignores a folder's own settings until you trust
    /// that folder interactively, but always honours settings given on the command line.
    /// Where a CLI is (an app started from the Finder has no shell PATH): Homebrew, /usr/local, ~/.local, Claude's own.
    /// On Linux the PATH after those; on Windows ~\.local\bin, Codex's own folder, then the PATH (`Tools`).
    public static func cli(_ name: String) -> String? { Tools.find(name) }

    public static let systemLaunch: Resolve = { r in
        guard let path = cli(r.runtime == .claude ? "claude" : "codex") else { return nil }
        return Launch(executable: URL(fileURLWithPath: path), arguments: arguments(r))
    }

    /// The command line for a run, without the program (testable where claude or codex is not installed).
    public static func arguments(_ r: Request) -> [String] {
        let safe = { (s: String?) -> String? in s.flatMap { $0.allSatisfy { $0.isLetter || $0.isNumber || "-._".contains($0) } && !$0.isEmpty ? $0 : nil } }
        let model = safe(r.model), effort = safe(r.effort)
        return r.runtime == .claude
            ? ["-p", r.prompt, "--permission-mode", "acceptEdits", "--output-format", "text", "--max-turns", String(r.maxTurns)]
                + (r.settings.map { ["--settings", $0.path] } ?? [])
                + (model.map { ["--model", $0] } ?? []) + (effort.map { ["--effort", $0] } ?? [])
            // a factory's folder or the Server room's workspace need not be a git repo of its own
            : ["exec", "-s", "workspace-write", "--skip-git-repo-check"] + (r.network ? ["-c", "sandbox_workspace_write.network_access=true"] : [])
                + (model.map { ["-m", $0] } ?? []) + (effort.map { ["-c", "model_reasoning_effort=\"\($0)\""] } ?? []) + [r.prompt]
    }

    /// The CEO's prompt: the same playbook the factory's files describe, and why it woke.
    public static func prompt(root: String, name: String, reason: WakeReason) -> String {
        if EngineRoom.isFolder(root) { return opsPrompt(root: root, reason: reason) }
        return """
        You are the CEO of the \(name) Dark Software Factory. Meatproxy's heartbeat started this run; nobody is watching it.
        This factory follows the Meatproxy factory contract (meatproxy-factory, the version in factory/contract.yml; \
        version 1 when that file is missing). Only what that contract says is agreed with Meatproxy. If factory/mandate.yml \
        exists, it is the user's mandate: what you may do on your own (ask, notify, off per item), your role (orchestrator: \
        delegate all work; hands-on: small things yourself) and their preferences. Follow it; it wins over autonomy.yml and \
        the playbook. Its team block names the helpers you may call in as sub-agents (subagent_type is the profile name, \
        defined in .claude/agents/) and at most how many of each may work at once: call in no others, and never more.
        Work from \(root). First read, in this order, and follow them exactly: factory/CHARTER.md, factory/README.md, \
        factory/CEO.md, then AGENTS.md in that folder and the AGENTS.md of the repos the playbook names.
        The user answers your yes/no questions in Meatproxy, which writes their answer into the decision file (status, \
        answered, and their note under ## Answer); read the answers there. Only the permissions in this project's \
        allowlist are available: when something you need is denied, say so in the briefing instead of working round it.
        Never ask the user for anything in the briefing's prose alone (contract v5): everything you need from them is an \
        open decision in factory/decisions/, so Meatproxy shows it under Needs you with a button. A choice is a yes/no \
        question as before. Something only they can do (sign in, allow a permission, change a setting, a manual step) is a \
        to-do: kind: todo, an imperative title, ## Why and ## How (the exact steps). Meatproxy shows Done and Not now: Done \
        (status yes) means check it on your next run and file a new to-do if it is still missing; Not now (status no) means \
        leave it until something changes. A decision with from: you was started by the user in Meatproxy and is already \
        answered yes (a release of finished work in ship): it is their own instruction and holds even where the mandate \
        keeps that item off; act on it first. In the briefing, ## Needs you lists only the open decisions, by id. \
        Work outside this project on shared infrastructure (CI runners, servers, the devops repository) is for the Server \
        room's DevOps agent (contract v6): file it as a to-do with for: devops, with ## Why and ## How written for that agent; \
        Meatproxy sends it there when the user presses Send to DevOps. Never name a specific agent or tool for it; an open \
        to-do of yours that still does, withdraw it and file it again with for: devops. When \
        factory/contract.yml declares a version below 6, raise it to 6.
        End the run with the briefing written. If questions are open, list them in your final message, numbered, each \
        answerable with yes or no.
        \(reason.prompt)
        """
    }

    /// The DevOps agent's prompt (docs/contracts/engine-room.md).
    public static func opsPrompt(root: String, reason: WakeReason) -> String {
        let tool = opsToolPath
        return """
        You are the DevOps agent of the Server room on this Mac. Meatproxy's heartbeat started this run; nobody is watching it.
        Work from \(root). This workspace follows the Meatproxy server room contract (meatproxy-engine-room, contract.yml); \
        only what that contract says is agreed with Meatproxy.
        Read README.md first: it has the exact file formats (a question is decisions/D-NNNN-<slug>.md with id, title and \
        status: open in its front matter). Then servers.json (your servers, what each allows, the last checks) and every \
        alert in alerts/ with status open.
        Reach servers only with the ops tool: run `\(tool) --ops list` first, then `\(tool) --ops <server> <action> [name]`. \
        Never use ssh, scp or sudo yourself. Diagnose with read actions. Where a server allows safe fixes, do the smallest \
        one that fixes the problem and check the result. A fix the tool refuses, or anything beyond its actions, becomes a \
        yes/no question in decisions/ (the factory decision format): what is wrong, the evidence, and the exact action on yes.
        Mark each alert you looked at status: handled, with what you found and did under ## Agent. An alert with kind: request \
        is work a factory needs on shared infrastructure, sent by the user: do what the ops tool and the servers allow, and \
        put the rest to the user as a question or a to-do with exact steps.
        Never ask the user in the journal's prose alone: what you need from them is an open decision, a yes/no question or, \
        for something only they can do, a to-do (kind: todo, with ## How); README.md has the format. A to-do is for the \
        user: never name an agent or tool to do it (who does code work is theirs to choose), and an open one of yours that \
        still does, rewrite it.
        End the run with journal/YYYY-MM-DD.md (a second run that day -2): ## Briefing (at most 5 items), ## Needs you \
        (only your open decisions, by id), ## Done.
        \(reason.prompt)
        """
    }

    /// The ops tool: this very app, in its CLI mode (the agent's allowlist names it).
    public static var opsToolPath: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    // MARK: state

    static func key(_ root: String) -> String {
        let base = PathText.name(root).lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
        var h: UInt32 = 2166136261
        for b in root.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return "\(base)-\(String(h, radix: 16))"
    }
    func stateURL(_ root: String) -> URL { folder.appendingPathComponent(Self.key(root) + ".json") }
    func lockURL(_ root: String) -> URL { folder.appendingPathComponent(Self.key(root) + ".lock") }
    public func logURL(_ root: String, started: Date) -> URL {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return folder.appendingPathComponent("logs/\(Self.key(root))/\(f.string(from: started).replacingOccurrences(of: ":", with: "")).log")
    }

    private struct State: Codable {
        var runs: [HeartbeatRun] = []; var ciSeen: [String: Int] = [:]; var since: Date?; var hold: String?; var skipped: Date?
        init() {}
        // tolerant: a field added later, or left out, has its default
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            runs = try c.decodeIfPresent([HeartbeatRun].self, forKey: .runs) ?? []
            ciSeen = try c.decodeIfPresent([String: Int].self, forKey: .ciSeen) ?? [:]
            since = try c.decodeIfPresent(Date.self, forKey: .since)
            hold = try c.decodeIfPresent(String.self, forKey: .hold)
            skipped = try c.decodeIfPresent(Date.self, forKey: .skipped)
        }
    }

    private func readState(_ root: String) -> State {
        guard let d = try? Data(contentsOf: stateURL(root)) else { return State() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(State.self, from: d)) ?? State()
    }
    private func writeState(_ root: String, _ s: State) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(s).write(wholeTo: stateURL(root))
    }

    /// The latest run (still running, or how it ended).
    public func lastRun(_ root: String) -> HeartbeatRun? { runs(root).last }
    /// The last runs, newest last (at most 20 are kept). A run still marked running whose process is gone (the app was
    /// closed during it) is closed off here, so it never stays "running" forever.
    public func runs(_ root: String) -> [HeartbeatRun] {
        var s = readState(root)
        guard s.runs.last?.outcome == .running, !isRunning(root), !lockHeld(root) else { return s.runs }
        lock.lock(); defer { lock.unlock() }
        s = readState(root)
        guard var last = s.runs.last, last.outcome == .running, running[root] == nil, !lockHeld(root) else { return s.runs }
        // when it really ended is unknown: its start is the honest bound (and starts no needless cooldown)
        last.outcome = .failed; last.ended = last.ended ?? last.started; last.detail = "Meatproxy was closed during the run; see the log"
        s.runs[s.runs.count - 1] = last
        writeState(root, s)
        releaseLock(root)
        return s.runs
    }

    /// The lock is held by a live process (a CEO run, here or started by the launch agent).
    func lockHeld(_ root: String) -> Bool {
        guard let text = try? String(contentsOf: lockURL(root), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return Processes.isAlive(pid)
    }

    /// The newest CI run id already seen for a repo (so an old failure never wakes the CEO twice).
    public func ciSeen(_ root: String, repo: String) -> Int? { readState(root).ciSeen[repo] }
    public func setCISeen(_ root: String, repo: String, id: Int) {
        lock.lock(); defer { lock.unlock() }
        var s = readState(root); s.ciSeen[repo] = id; writeState(root, s)
    }

    /// Since when this factory has a heartbeat: beats before that are never caught up. Kept on disk, so the launch
    /// agent (a new process every five minutes) and the app agree.
    public func watchedSince(_ root: String, now: Date = Date()) -> Date {
        lock.lock(); defer { lock.unlock() }
        var s = readState(root)
        if let since = s.since { return since }
        s.since = now; writeState(root, s)
        return now
    }

    /// A hold on this factory that waits for you (the CI breaker), or nil.
    public func hold(_ root: String) -> String? { readState(root).hold }
    public func setHold(_ root: String, _ why: String?) {
        lock.lock(); defer { lock.unlock() }
        var s = readState(root); s.hold = why; writeState(root, s)
    }

    /// Scheduled beats up to here were skipped by a guard (the day's cap, a hold, a plan limit): never caught up later.
    public func skipped(_ root: String) -> Date? { readState(root).skipped }
    public func skip(_ root: String, through: Date) {
        lock.lock(); defer { lock.unlock() }
        var s = readState(root); s.skipped = through; writeState(root, s)
    }

    // MARK: plan limits

    var limitsURL: URL { folder.appendingPathComponent("plan-limits.json") }
    /// Until when a runtime's plan limit holds every factory on it (nil: free).
    public func planLimit(_ runtime: Heartbeat.Runtime, now: Date = Date()) -> Date? {
        guard let d = try? Data(contentsOf: limitsURL), let m = try? JSONDecoder().decode([String: Date].self, from: d),
              let until = m[runtime.rawValue], until > now else { return nil }
        return until
    }
    func setPlanLimit(_ runtime: Heartbeat.Runtime, until: Date) {
        var m = (try? JSONDecoder().decode([String: Date].self, from: Data(contentsOf: limitsURL))) ?? [:]
        m[runtime.rawValue] = until
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(m).write(wholeTo: limitsURL)
    }

    /// A run's output says the plan's limit was hit: until when (the reset it names, or an hour from now). Nil otherwise.
    static func planLimit(in log: String, now: Date) -> Date? {
        let lower = log.lowercased()
        let hit = ["usage limit", "rate limit", "limit reached", "hit your limit", "limit will reset", "quota exceeded"].contains { lower.contains($0) }
        guard hit else { return nil }
        // "Claude AI usage limit reached|1763215200": the reset as epoch seconds
        if let r = log.range(of: #"\|(\d{10})\b"#, options: .regularExpression),
           let t = TimeInterval(log[r].dropFirst()), t > now.timeIntervalSince1970 { return Date(timeIntervalSince1970: t) }
        return now.addingTimeInterval(3600)
    }

    // MARK: the lock

    /// Takes the factory's lock: a file holding our process id. A lock left by a process that is gone is taken over.
    func takeLock(_ root: String) -> Bool {
        let url = lockURL(root)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let text = try? String(contentsOf: url, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid != Processes.own, Processes.isAlive(pid) {
            return false
        }
        return (try? "\(Processes.own)".write(wholeTo: url)) != nil
    }
    func releaseLock(_ root: String) { try? FileManager.default.removeItem(at: lockURL(root)) }

    /// Stops a factory's run from outside (you take over in the terminal); its end records why.
    public func stop(_ root: String, because why: String) {
        lock.lock(); let p = running[root]; if p != nil { stopReason[root] = why }; lock.unlock()
        if p?.isRunning == true { p?.terminate() }
    }

    /// Stops every run this process started ("Pause all").
    public func stopAll() {
        lock.lock(); let ps = Array(running.values); lock.unlock()
        for p in ps where p.isRunning { p.terminate() }
    }

    public func isRunning(_ root: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running[root] != nil
    }

    // MARK: running

    /// Starts a run unless one is already running for this factory (here or in the launch agent). Returns false when it
    /// did not start. `done` is called on the main queue when the run ends.
    @discardableResult
    public func start(root: String, name: String, heartbeat: Heartbeat, reason: WakeReason, now: Date = Date(),
                      done: (@Sendable (HeartbeatRun) -> Void)? = nil) -> Bool {
        // whole seconds: the state file keeps dates in ISO 8601 without fractions, and a run is found back by its start
        let now = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        lock.lock()
        guard running[root] == nil, takeLock(root) else { lock.unlock(); return false }
        var run = HeartbeatRun(started: now, reason: reason, outcome: .running)
        var state = readState(root)
        let settings = URL(fileURLWithPath: root).appendingPathComponent(".claude/settings.json")
        let allowlist = FileManager.default.fileExists(atPath: settings.path) ? settings : nil
        if heartbeat.runtime == .claude, allowlist == nil {
            run.warning = "No allowlist: without .claude/settings.json in the project the CEO can only read and edit files"
        }
        let pick = heartbeat.models.choice(for: reason)
        let used = [pick.model, pick.effort].compactMap { $0 }.joined(separator: " · ")
        run.model = used.isEmpty ? nil : used
        guard let launch = resolve(Request(runtime: heartbeat.runtime, prompt: Self.prompt(root: root, name: name, reason: reason),
                                           maxTurns: heartbeat.maxTurns, settings: allowlist, network: EngineRoom.isFolder(root),
                                           model: pick.model, effort: pick.effort)) else {
            run.ended = now; run.outcome = .failed; run.detail = "\(heartbeat.runtime.label) is not installed"
            state.runs = Array((state.runs + [run]).suffix(20)); writeState(root, state)
            releaseLock(root); lock.unlock()
            if let done { DispatchQueue.main.async { done(run) } }
            return false
        }
        let log = logURL(root, started: now)
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        Files.create(log, contents: nil)
        let p = Process()
        p.executableURL = launch.executable
        p.arguments = launch.arguments
        p.currentDirectoryURL = directory(root)
        var env = UserEnvironment.withSSHAgent()
        // a CEO is its own session: nothing of a Claude Code session the app may have been started from leaks in
        for k in env.keys where k.hasPrefix("CLAUDE") || k == "ANTHROPIC_BASE_URL" { env[k] = nil }
        Tools.addSearchPath(to: &env)
        p.environment = env
        if let fh = try? FileHandle(forWritingTo: log) { p.standardOutput = fh; p.standardError = fh }
        p.standardInput = FileHandle.nullDevice
        state.runs = Array((state.runs + [run]).suffix(20)); writeState(root, state)
        running[root] = p
        lock.unlock()

        let timer = DispatchWorkItem { [weak p] in if p?.isRunning == true { p?.terminate() } }
        p.terminationHandler = { [weak self] proc in
            timer.cancel()
            guard let self else { return }
            self.lock.lock()
            var s = self.readState(root)
            let timedOut = proc.terminationReason == .uncaughtSignal && Date().timeIntervalSince(now) >= Self.timeout - 1
            run.ended = Date()
            run.outcome = timedOut ? .timedOut : proc.terminationStatus == 0 ? .ok : .failed
            run.detail = timedOut ? "stopped after \(Int(Self.timeout / 60)) minutes" : "exit \(proc.terminationStatus)"
            if let why = self.stopReason.removeValue(forKey: root) { run.outcome = .takenOver; run.detail = why }
            if let fh = try? FileHandle(forReadingFrom: log) {
                let size = (try? fh.seekToEnd()) ?? 0
                try? fh.seek(toOffset: size > 8192 ? size - 8192 : 0)
                let tail = String(decoding: fh.readDataToEndOfFile(), as: UTF8.self)
                try? fh.close()
                // the plan's limit: every factory on this runtime waits for its reset, no retries (D48)
                if run.outcome != .ok, let until = Self.planLimit(in: tail, now: Date()) {
                    self.setPlanLimit(heartbeat.runtime, until: until)
                    run.detail = "\(heartbeat.runtime.label) plan limit reached"
                }
            }
            if let k = s.runs.lastIndex(where: { $0.started == now }) { s.runs[k] = run } else { s.runs.append(run) }
            self.writeState(root, s)
            self.running[root] = nil
            self.releaseLock(root)
            self.lock.unlock()
            if let done { DispatchQueue.main.async { done(run) } }
        }
        do {
            try Processes.start(p)
        } catch {
            lock.lock()
            running[root] = nil
            run.ended = Date(); run.outcome = .failed; run.detail = "could not start: \(error.localizedDescription)"
            var s = readState(root)
            if let k = s.runs.lastIndex(where: { $0.started == now }) { s.runs[k] = run }
            writeState(root, s); releaseLock(root); lock.unlock()
            if let done { DispatchQueue.main.async { done(run) } }
            return false
        }
        // the lock now names the CEO process itself: if the app closes, the run still holds it until it really ends
        try? "\(p.processIdentifier)".write(wholeTo: lockURL(root))
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: timer)
        return true
    }

    /// Waits for a factory's run to end (the launch agent's headless mode).
    public func wait(_ root: String) {
        lock.lock(); let p = running[root]; lock.unlock()
        p?.waitUntilExit()
        // the termination handler runs on another queue: give it a moment to write the state
        for _ in 0..<50 where isRunning(root) { Thread.sleep(forTimeInterval: 0.05) }
    }
}
