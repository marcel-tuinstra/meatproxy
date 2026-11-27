import Foundation
import FactoryCore

/// Decides when each factory's CEO wakes (D47) and asks the runner to start it: on its heartbeat (a beat missed while
/// the app was closed runs once, "caught up"), a few minutes after your answers (a window, so several answers make one
/// run), at once for "Run now", and on a new failed CI run on a main branch. A factory you just switched on does not
/// catch up beats from before. Not thread-safe: use it from the main queue.
public final class HeartbeatCenter {
    public let runner: HeartbeatRunner
    /// wake-ups waiting for their moment, per project folder
    public private(set) var pending: [String: (reason: WakeReason, at: Date)] = [:]
    /// what a factory's work cost today at API prices (D61), for its cost cap; nil: no cap is checked
    public var costToday: ((String) -> Double)?
    /// the name of the runtime's provider when its status page says it is down (D69), else nil
    public var providerDown: ((Heartbeat.Runtime) -> String?)?
    /// whether a factory has its starter files (D76); nil: every factory counts as set up
    public var isSetUp: ((String) -> Bool)?
    private let ciQueue = DispatchQueue(label: "dev.tuinstra.meatproxy.ci", qos: .utility)
    private var ciChecking = false
    /// a CI look is under way (its answer comes back on the main queue)
    public var isCheckingCI: Bool { ciChecking }
    /// the queue the center is used from, where a CI look reports back (the main queue in the app)
    public var queue: DispatchQueue = .main
    /// the gh command (tests swap it): the JSON of `gh run list` for a repo folder, or nil
    public var ghRuns: @Sendable (URL) -> Data? = HeartbeatCenter.systemGHRuns

    public init(runner: HeartbeatRunner = HeartbeatRunner()) { self.runner = runner }

    /// factories you took over in the terminal: their heartbeat waits until you close that tab (D57)
    public private(set) var takenOver: Set<String> = []
    /// You take over: a running run stops (it is yours now), and nothing starts until you hand it back.
    public func takeOver(_ root: String) {
        takenOver.insert(root)
        runner.stop(root, because: "you took over in the terminal")
    }
    public func handBack(_ root: String) { takenOver.remove(root) }

    // MARK: wake-ups

    /// A reason to wake a factory: your answers wait for the window (and merge), anything else is due at once.
    public func wake(_ root: String, _ reason: WakeReason, now: Date = Date()) {
        // a wake that waits for its window never pushes aside another kind already pending (that run reads both)
        if let p = pending[root] {
            switch (p.reason, reason) {
            case (.answered, .answered), (.idea, .idea): break
            case (_, .answered), (_, .idea): return
            default: break
            }
        }
        if case .answered(let ids) = reason {
            var all = ids
            if case .answered(let before)? = pending[root]?.reason { all = before + ids.filter { !before.contains($0) } }
            pending[root] = (.answered(all), now.addingTimeInterval(Heartbeat.answerWindow))
        } else if case .idea(let ids) = reason {
            var all = ids
            if case .idea(let before)? = pending[root]?.reason { all = before + ids.filter { !before.contains($0) } }
            pending[root] = (.idea(all), now.addingTimeInterval(Heartbeat.answerWindow))
        } else {
            pending[root] = (reason, now)
        }
    }

    /// What wakes this factory next and when, for the HUD.
    public func state(_ root: String, heartbeat: Heartbeat, pauseAll: Bool = false, now: Date = Date()) -> HeartbeatState {
        let runs = runner.runs(root)
        return HeartbeatState(config: heartbeat, last: runs.last, next: heartbeat.next(after: now), pending: pending[root],
                              blocked: runs.last?.outcome == .running ? nil : block(root, heartbeat, pauseAll: pauseAll, runs: runs, now: now),
                              runsToday: Self.automaticToday(runs, now: now))
    }

    /// Lifts the hold on a factory (Resume) and wakes it.
    public func resume(_ root: String, now: Date = Date()) {
        runner.setHold(root, nil)
        wake(root, .runNow, now: now)
    }

    // MARK: guards (D48)

    /// this many CI wakes in a row trip the breaker: the factory waits for you
    public static let ciBreaker = 2
    /// this many Sentry wakes in a row trip the same kind of breaker (D61)
    public static let sentryBreaker = 3

    static func automaticToday(_ runs: [HeartbeatRun], now: Date, calendar cal: Calendar = .current) -> Int {
        runs.filter { cal.isDate($0.started, inSameDayAs: now) && $0.reason != .runNow }.count
    }

    /// What keeps an automatic wake from starting now, if anything. "Run now" only waits for "Pause all".
    func block(_ root: String, _ hb: Heartbeat, pauseAll: Bool, runs: [HeartbeatRun], runNow: Bool = false, now: Date) -> Block? {
        if pauseAll { return .allPaused }
        if let isSetUp, !isSetUp(root) { return .notSetUp }
        if takenOver.contains(root) { return .takenOver }
        if !runNow {
            if let why = runner.hold(root) { return .held(why) }
            if let until = runner.planLimit(hb.runtime, now: now) { return .planLimit(hb.runtime, until: until) }
            if Self.automaticToday(runs, now: now) >= hb.runsPerDay { return .dailyCap(hb.runsPerDay) }
            if let cap = hb.maxCostPerDay, let spent = costToday?(root), spent >= cap { return .costCap(spent: spent, cap: cap) }
            if let name = providerDown?(hb.runtime) { return .providerDown(name) }
            if let last = runs.last?.ended ?? runs.last?.started {
                let until = last.addingTimeInterval(TimeInterval(hb.cooldownMinutes * 60))
                if until > now { return .coolingDown(until: until) }
            }
        }
        // every factory has its own CEO: factories never wait for each other, only for their own run (the lock)
        return nil
    }

    /// Starts every factory whose moment has come. Call it every few seconds. `names` gives a factory its display name.
    /// Returns the folders that started.
    @discardableResult
    public func tick(_ settings: ProjectSettings, names: [String: String] = [:], now: Date = Date(),
                     done: (@Sendable (String, HeartbeatRun) -> Void)? = nil) -> [String] {
        var started: [String] = []
        if settings.pauseAll { return [] }
        var entries = settings.projects.filter(\.factory)
        if settings.devops.enabled {
            entries.append(.init(root: EngineRoom.folder.path, pinned: false, factory: true, heartbeat: settings.devops.heartbeat))
        }
        for e in entries {
            guard !runner.isRunning(e.root), !takenOver.contains(e.root) else { continue }
            var reason: WakeReason?
            if let p = pending[e.root], p.at <= now { reason = p.reason }
            else if let beat = scheduledBeat(e, now: now) { reason = beat }
            guard let reason else { continue }
            let runNow = reason == .runNow
            let runs = runner.runs(e.root)
            // the CI breaker: the CEO already woke for CI twice in a row and CI fails again. It waits for you.
            if case .ciFailed = reason, runs.suffix(Self.ciBreaker).count == Self.ciBreaker,
               runs.suffix(Self.ciBreaker).allSatisfy({ if case .ciFailed = $0.reason { return true }; return false }) {
                runner.setHold(e.root, "Held: CI woke the CEO \(Self.ciBreaker) times in a row and still fails")
                pending[e.root] = nil
                continue
            }
            // the Sentry breaker: three Sentry wakes in a row and still new errors. It waits for you.
            if case .sentry = reason, runs.suffix(Self.sentryBreaker).count == Self.sentryBreaker,
               runs.suffix(Self.sentryBreaker).allSatisfy({ if case .sentry = $0.reason { return true }; return false }) {
                runner.setHold(e.root, "Held: Sentry woke the CEO \(Self.sentryBreaker) times in a row and errors keep coming")
                pending[e.root] = nil
                continue
            }
            // a guard: the wake waits (it stays pending, a scheduled beat stays due) until the guard lifts
            if !e.heartbeat.paused || runNow, let b = block(e.root, e.heartbeat, pauseAll: false, runs: runs, runNow: runNow, now: now) {
                // a beat that only has to wait for the cooldown stays due; one a guard stops is skipped
                switch (b, reason) {
                case (.coolingDown, _): break
                case (_, .schedule), (_, .caughtUp): runner.skip(e.root, through: now)
                default: break
                }
                continue
            }
            if !e.heartbeat.paused || runNow {
                let name = names[e.root] ?? (EngineRoom.isFolder(e.root) ? EngineRoom.displayName : WorldBuilder.pretty(PathText.name(e.root)))
                if runner.start(root: e.root, name: name, heartbeat: e.heartbeat, reason: reason, now: now,
                                done: done.map { d in { run in d(e.root, run) } }) {
                    started.append(e.root)
                }
            }
            // a wake-up is used up whether the run started or was refused (a run already going covers it)
            if let p = pending[e.root], p.at <= now { pending[e.root] = nil }
        }
        return started
    }

    /// The scheduled beat that is due for a factory, if any: after its last run (or after we started watching it).
    func scheduledBeat(_ e: ProjectSettings.Entry, now: Date) -> WakeReason? {
        var last = runner.lastRun(e.root)?.started ?? runner.watchedSince(e.root, now: now)
        if let s = runner.skipped(e.root), s > last { last = s }
        guard let beat = e.heartbeat.due(lastRun: last, now: now) else { return nil }
        // more than ten minutes late: the app was closed or asleep at the time
        return now.timeIntervalSince(beat) > 600 ? .caughtUp(beat) : .schedule(beat)
    }

    // MARK: CI

    /// Looks for new failed CI runs on main, master or develop in each factory's repos (its folder, or the repos in
    /// code/). The first look only notes what is there; a failure after that wakes the CEO. Runs off the main queue
    /// and reports back on it.
    public func checkCI(_ settings: ProjectSettings, now: Date = Date()) {
        guard !ciChecking else { return }
        let factories = settings.projects.filter { $0.factory && $0.heartbeat.wakeOnCI && !$0.heartbeat.paused }
        guard !factories.isEmpty else { return }
        ciChecking = true
        let runner = self.runner, gh = ghRuns, home = queue
        ciQueue.async {
            var wakes: [(String, WakeReason)] = []
            for e in factories {
                for repo in Self.repos(in: e.root) {
                    guard let data = gh(repo), let runs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { continue }
                    let main = runs.filter { ["main", "master", "develop"].contains($0["headBranch"] as? String ?? "") }
                    let newest = main.compactMap { $0["databaseId"] as? Int }.max() ?? 0
                    let name = repo.lastPathComponent
                    guard let seen = runner.ciSeen(e.root, repo: name) else {
                        if newest > 0 { runner.setCISeen(e.root, repo: name, id: newest) }
                        continue
                    }
                    let failed = main.filter { ($0["databaseId"] as? Int ?? 0) > seen && ($0["conclusion"] as? String) == "failure" }
                        .compactMap { $0["databaseId"] as? Int }.max()
                    if newest > seen { runner.setCISeen(e.root, repo: name, id: newest) }
                    if let failed { wakes.append((e.root, .ciFailed(repo: name, run: String(failed)))) }
                }
            }
            home.async {
                self.ciChecking = false
                for (root, reason) in wakes { self.wake(root, reason, now: now) }
            }
        }
    }

    /// The git repos of a project: the folder itself, or its code/<repo> folders.
    static func repos(in root: String) -> [URL] {
        let fm = FileManager.default, r = URL(fileURLWithPath: root)
        if fm.fileExists(atPath: r.appendingPathComponent(".git").path) { return [r] }
        let code = r.appendingPathComponent("code")
        return ((try? fm.contentsOfDirectory(at: code, includingPropertiesForKeys: nil)) ?? [])
            .filter { fm.fileExists(atPath: $0.appendingPathComponent(".git").path) }.sorted { $0.path < $1.path }
    }

    /// `gh run list` in a repo folder, with the user's own gh login; nil when gh is missing or fails (20 s at most).
    public static let systemGHRuns: @Sendable (URL) -> Data? = { repo in
        guard let gh = Tools.find("gh") else { return nil }
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = ["run", "list", "--limit", "15", "--json", "databaseId,conclusion,headBranch,status"]
        p.currentDirectoryURL = repo
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try Processes.start(p) } catch { return nil }
        let deadline = Date().addingTimeInterval(20)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        return out.fileHandleForReading.readDataToEndOfFile()
    }
}
