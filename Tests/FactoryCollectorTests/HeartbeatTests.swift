import Foundation
import Testing
@testable import FactoryCollector
@testable import FactoryCore

/// The heartbeat (D47) and the floors (D46), with made-up projects and a fake runtime: no real CEO ever runs here.
struct HeartbeatTests {
    private let fm = FileManager.default
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!; return c }
    private func at(_ s: String) -> Date {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "Europe/Amsterdam")!; f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)!
    }
    private func tempDir() throws -> URL {
        let u = fm.temporaryDirectory.appendingPathComponent("sf-heartbeat-\(UUID().uuidString)")
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // MARK: the schedule

    @Test func weekdaysBeatOnWeekdaysOnly() {
        let hb = Heartbeat(days: .weekdays, times: ["07:10"])
        // Friday 20 Nov 2026 08:00 → the next beat is Monday 23 Nov 07:10
        #expect(hb.next(after: at("2026-11-20T08:00:00+01:00"), calendar: cal) == at("2026-11-23T07:10:00+01:00"))
        #expect(hb.next(after: at("2026-11-16T06:00:00+01:00"), calendar: cal) == at("2026-11-16T07:10:00+01:00"))
        #expect(Heartbeat(days: .everyDay, times: ["07:10"]).next(after: at("2026-11-21T08:00:00+01:00"), calendar: cal) == at("2026-11-22T07:10:00+01:00"))
        #expect(hb.summary == "Weekdays 07:10")
        #expect(Heartbeat(days: .everyDay, everyMinutes: 240).summary == "Every day, every 4 h")
    }

    @Test func intervalsFallOnWholeSteps() {
        let hb = Heartbeat(days: .everyDay, everyMinutes: 240)
        #expect(hb.next(after: at("2026-11-16T09:30:00+01:00"), calendar: cal) == at("2026-11-16T12:00:00+01:00"))
    }

    @Test func aMissedBeatRunsOnceAndPausedNever() {
        let hb = Heartbeat(days: .weekdays, times: ["07:10", "13:00"])
        // last run Monday 07:12; the app was closed until Tuesday 15:00: one catch-up for the latest beat, Tuesday 13:00
        #expect(hb.due(lastRun: at("2026-11-16T07:12:00+01:00"), now: at("2026-11-17T15:00:00+01:00"), calendar: cal) == at("2026-11-17T13:00:00+01:00"))
        #expect(hb.due(lastRun: at("2026-11-17T13:01:00+01:00"), now: at("2026-11-17T15:00:00+01:00"), calendar: cal) == nil)
        var paused = hb; paused.paused = true
        #expect(paused.due(lastRun: nil, now: at("2026-11-17T15:00:00+01:00"), calendar: cal) == nil)
        #expect(paused.summary == "Paused")
    }

    // MARK: the runner

    /// A fake runtime: /bin/sh running `script`, with the prompt as its argument. Only where there is a /bin/sh.
    private func fake(_ script: String) -> HeartbeatRunner.Resolve {
        { r in HeartbeatRunner.Launch(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, "sh", r.prompt]) }
    }
    /// A fake runtime that just succeeds, on every platform.
    private let quick: HeartbeatRunner.Resolve = { _ in Stub.succeed }

    private func waitFor(_ cond: () -> Bool) {
        let end = Date().addingTimeInterval(5)
        while !cond() && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
    }

    @Test(.enabled(if: Stub.hasShell)) func aRunWritesItsLogAndOutcome() throws {
        let state = try tempDir(), project = try tempDir()
        // it runs long enough for the second start to find it running (on Linux a bare echo is over before that)
        let runner = HeartbeatRunner(folder: state, resolve: fake(#"sleep 0.3; echo "woke: $1" | head -c 40"#))
        #expect(runner.start(root: project.path, name: "Pebble", heartbeat: Heartbeat(), reason: .runNow))
        #expect(!runner.start(root: project.path, name: "Pebble", heartbeat: Heartbeat(), reason: .runNow))   // one at a time
        runner.wait(project.path)
        let last = try #require(runner.lastRun(project.path))
        #expect(last.outcome == .ok && last.reason == .runNow && last.ended != nil)
        #expect(runner.runs(project.path).count == 1)        // the finished run replaces the running one
        let logs = try fm.contentsOfDirectory(at: state.appendingPathComponent("logs/\(HeartbeatRunner.key(project.path))"), includingPropertiesForKeys: nil)
        #expect(try String(contentsOf: try #require(logs.first), encoding: .utf8).hasPrefix("woke: You are the CEO of the Pebble"))
        #expect(!fm.fileExists(atPath: runner.lockURL(project.path).path))
    }

    @Test func aFailingOrMissingRuntimeSaysSo() throws {
        let state = try tempDir(), project = try tempDir()
        let failing = HeartbeatRunner(folder: state, resolve: { _ in Stub.exit(3) })
        failing.start(root: project.path, name: "P", heartbeat: Heartbeat(), reason: .runNow)
        failing.wait(project.path)
        #expect(failing.lastRun(project.path)?.outcome == .failed)
        #expect(failing.lastRun(project.path)?.detail == "exit 3")
        let missing = HeartbeatRunner(folder: try tempDir(), resolve: { _ in nil })
        #expect(!missing.start(root: project.path, name: "P", heartbeat: Heartbeat(runtime: .codex), reason: .runNow))
        #expect(missing.lastRun(project.path)?.detail == "Codex is not installed")
    }

    @Test func anotherProcessHoldingTheLockStopsARun() throws {
        let state = try tempDir(), project = try tempDir()
        let runner = HeartbeatRunner(folder: state, resolve: quick)
        // the launch agent (another live process) holds the lock
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
        try Stub.whileAnotherProcessLives { pid in
            try "\(pid)".write(wholeTo: runner.lockURL(project.path))
            #expect(!runner.start(root: project.path, name: "P", heartbeat: Heartbeat(), reason: .runNow))
        }
        // a lock left by a process that is gone is taken over
        try "999999".write(wholeTo: runner.lockURL(project.path))
        #expect(runner.start(root: project.path, name: "P", heartbeat: Heartbeat(), reason: .runNow))
        runner.wait(project.path)
    }

    // MARK: the center

    @Test func answersWaitForTheirWindowAndMerge() throws {
        let project = try tempDir()
        let center = HeartbeatCenter(runner: HeartbeatRunner(folder: try tempDir(), resolve: quick))
        let settings = ProjectSettings(projects: [.init(root: project.path, factory: true, heartbeat: Heartbeat(paused: false))])
        let t0 = Date()
        center.wake(project.path, .answered(["D-0007"]), now: t0)
        center.wake(project.path, .answered(["D-0008"]), now: t0.addingTimeInterval(60))
        #expect(center.tick(settings, now: t0.addingTimeInterval(120)).isEmpty)              // still in the window
        if case .answered(let ids)? = center.pending[project.path]?.reason { #expect(ids == ["D-0007", "D-0008"]) } else { Issue.record("no merged answer") }
        #expect(center.tick(settings, now: t0.addingTimeInterval(60 + Heartbeat.answerWindow + 1)) == [project.path])
        center.runner.wait(project.path)
        #expect(center.runner.lastRun(project.path)?.reason == .answered(["D-0007", "D-0008"]))
        #expect(center.pending[project.path] == nil)
    }

    @Test func runNowWorksWhenPausedAndANewFactoryDoesNotCatchUp() throws {
        let project = try tempDir()
        let center = HeartbeatCenter(runner: HeartbeatRunner(folder: try tempDir(), resolve: quick))
        var e = ProjectSettings.Entry(root: project.path, factory: true, heartbeat: Heartbeat(days: .everyDay, times: ["00:01"]))
        // switched on now: this morning's 00:01 beat is not caught up
        #expect(center.tick(ProjectSettings(projects: [e])).isEmpty)
        // another process (the launch agent) agrees: the factory is watched since then, so tomorrow's beat is due
        let agent = HeartbeatCenter(runner: HeartbeatRunner(folder: center.runner.folder, resolve: quick))
        #expect(agent.tick(ProjectSettings(projects: [e])).isEmpty)
        #expect(agent.scheduledBeat(e, now: Date().addingTimeInterval(86400 + 120)) != nil)
        e.heartbeat.paused = true
        center.wake(project.path, .runNow)
        #expect(center.tick(ProjectSettings(projects: [e])) == [project.path])
        center.runner.wait(project.path)
    }

    /// A factory that is not set up waits for its starter files: not even Run now starts a CEO without its playbook.
    @Test func aFactoryWaitsUntilItIsSetUp() throws {
        let project = try tempDir()
        let center = HeartbeatCenter(runner: HeartbeatRunner(folder: try tempDir(), resolve: quick))
        center.isSetUp = { FactoryScaffold.isSetUp($0) }
        let e = ProjectSettings.Entry(root: project.path, factory: true, heartbeat: Heartbeat(paused: false))
        center.wake(project.path, .runNow)
        #expect(center.tick(ProjectSettings(projects: [e])).isEmpty)
        #expect(center.block(project.path, e.heartbeat, pauseAll: false, runs: [], runNow: true, now: Date()) == .notSetUp)
        #expect(Block.notSetUp.text == "Not set up yet: create its starter files first")
        try FactoryScaffold.create(FactoryScaffold.plan(root: project.path, name: "P").filter { !$0.optional }, root: project.path)
        #expect(center.tick(ProjectSettings(projects: [e])) == [project.path])
        center.runner.wait(project.path)
    }

    @Test func ciFailuresWakeOnlyWhenNew() throws {
        let project = try tempDir()
        try fm.createDirectory(at: project.appendingPathComponent("code/app/.git"), withIntermediateDirectories: true)
        let center = HeartbeatCenter(runner: HeartbeatRunner(folder: try tempDir(), resolve: quick))
        let settings = ProjectSettings(projects: [.init(root: project.path, factory: true)])
        nonisolated(unsafe) var runs = #"[{"databaseId": 10, "conclusion": "failure", "headBranch": "develop"}]"#
        center.ghRuns = { _ in runs.data(using: .utf8) }
        // the center's own queue is the main queue in the app; here a queue of the test's, read through it
        let q = DispatchQueue(label: "test.center")
        center.queue = q
        func pending() -> WakeReason? { q.sync { center.pending[project.path]?.reason } }
        q.sync { center.checkCI(settings) }
        waitFor { center.runner.ciSeen(project.path, repo: "app") != nil && !q.sync { center.isCheckingCI } }
        #expect(pending() == nil)             // the first look only notes the old failure
        runs = #"[{"databaseId": 11, "conclusion": "failure", "headBranch": "develop"}, {"databaseId": 12, "conclusion": "failure", "headBranch": "feature/x"}]"#
        q.sync { center.checkCI(settings) }
        waitFor { pending() != nil }
        #expect(pending() == .ciFailed(repo: "app", run: "11"))
    }

    // MARK: settings and floors

    @Test func factoriesJSONIsTakenOver() throws {
        let folder = try tempDir()
        try #"{"factories":["/demo/pebble"]}"#.write(wholeTo: folder.appendingPathComponent("factories.json"))
        let store = ProjectSettingsStore(folder: folder)
        let s = store.load()
        #expect(s.factoryRoots == ["/demo/pebble"] && s.pinnedRoots == ["/demo/pebble"])
        #expect(s.entry("/demo/pebble")?.heartbeat == Heartbeat())
        var changed = s
        changed.update("/demo/shop") { $0.pinned = true }
        changed.update("/demo/pebble") { $0.factory = false; $0.pinned = false }      // neither: dropped
        try store.save(changed)
        #expect(store.load().projects.map(\.root) == ["/demo/shop"])
    }

    @Test func chatsShareOneFloorAndPinnedProjectsStay() {
        let now = Date()
        func s(_ id: String, _ cwd: String) -> Session { Session(id: id, provider: .claude, cwd: cwd, title: id, lastAt: now, turnOpen: true) }
        let resolve: (String) -> ProjectKey = { $0 == "~" ? ProjectKey(root: "~", name: "", isChat: true) : ProjectKey(root: $0, name: "Shop", isChat: false) }
        var w = WorldBuilder.build([s("c1", "~"), s("c2", "~"), s("p1", "/demo/shop")], now: now, resolve: resolve)
        #expect(w.projects.filter(\.isChat).map(\.name) == ["Chats"])
        #expect(w.projects.first { $0.isChat }?.sessions.count == 2)
        #expect(WorldBuilder.build([s("c1", "~")], now: now, showChats: false, resolve: resolve).projects.isEmpty)
        WorldBuilder.pin(["/demo/quiet", "/demo/shop"], to: &w)
        #expect(w.projects.map(\.root).sorted() == ["/demo/quiet", "/demo/shop", "~"])
    }
}

/// The guards against a factory burning your plan (D48), with a fake runtime.
struct HeartbeatGuardTests {
    private func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("sf-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private let ok: HeartbeatRunner.Resolve = { _ in Stub.succeed }

    @Test func aProviderThatIsDownHoldsItsFactoriesOnly() throws {
        let p = try tempDir()
        let center = HeartbeatCenter(runner: HeartbeatRunner(folder: try tempDir(), resolve: ok))
        let hb = Heartbeat(paused: false)
        let s = ProjectSettings(projects: [.init(root: p.path, factory: true, heartbeat: hb)])
        center.providerDown = { $0 == .claude ? "Claude" : nil }
        let t0 = Date()
        center.wake(p.path, .ciFailed(repo: "app", run: "1"), now: t0)
        #expect(center.tick(s, now: t0).isEmpty)
        #expect(center.state(p.path, heartbeat: hb, now: t0).blocked == .providerDown("Claude"))
        #expect(Block.providerDown("Claude").text.contains("Claude is down"))
        // a factory on Codex is not held by Claude's outage
        var codex = hb; codex.runtime = .codex
        #expect(center.state(p.path, heartbeat: codex, now: t0).blocked == nil)
        // back up: it runs
        center.providerDown = { _ in nil }
        #expect(center.tick(s, now: t0) == [p.path]); center.runner.wait(p.path)
    }

    @Test func costCapHoldsAutomaticRunsButNotRunNow() throws {
        let p = try tempDir()
        let center = HeartbeatCenter(runner: HeartbeatRunner(folder: try tempDir(), resolve: ok))
        var hb = Heartbeat(paused: false); hb.maxCostPerDay = 5
        let s = ProjectSettings(projects: [.init(root: p.path, factory: true, heartbeat: hb)])
        center.costToday = { _ in 6.5 }
        let t0 = Date()
        center.wake(p.path, .ciFailed(repo: "app", run: "1"), now: t0)
        #expect(center.tick(s, now: t0).isEmpty)
        #expect(center.state(p.path, heartbeat: hb, now: t0).blocked == .costCap(spent: 6.5, cap: 5))
        // under the cap it runs
        center.costToday = { _ in 1 }
        #expect(center.tick(s, now: t0) == [p.path]); center.runner.wait(p.path)
        // no cap set: never held for cost
        center.costToday = { _ in 1000 }
        var free = hb; free.maxCostPerDay = nil
        #expect(center.state(p.path, heartbeat: free, now: t0.addingTimeInterval(3 * 3600)).blocked == nil)
    }

    @Test func cooldownDailyCapAndRunNow() throws {
        let p = try tempDir()
        let center = HeartbeatCenter(runner: HeartbeatRunner(folder: try tempDir(), resolve: ok))
        var hb = Heartbeat(paused: false); hb.runsPerDay = 2; hb.cooldownMinutes = 20
        let s = ProjectSettings(projects: [.init(root: p.path, factory: true, heartbeat: hb)])
        let t0 = Date()
        center.wake(p.path, .ciFailed(repo: "app", run: "1"), now: t0)
        #expect(center.tick(s, now: t0) == [p.path]); center.runner.wait(p.path)
        // ten minutes later CI fails again: it waits for the cooldown, and stays pending
        center.wake(p.path, .ciFailed(repo: "app", run: "2"), now: t0.addingTimeInterval(600))
        #expect(center.tick(s, now: t0.addingTimeInterval(600)).isEmpty)
        let st = center.state(p.path, heartbeat: hb, now: t0.addingTimeInterval(600))
        if case .coolingDown? = st.blocked {} else { Issue.record("no cooldown") }
        #expect(center.tick(s, now: t0.addingTimeInterval(1500)) == [p.path]); center.runner.wait(p.path)
        // two automatic runs today: the cap. Run now is yours and still runs. (The cap counts per calendar day: when this
        // test runs just before midnight, the third run falls on a new day and is allowed.)
        let later = t0.addingTimeInterval(3000 + Heartbeat.answerWindow + 1)
        let sameDay = Calendar.current.isDate(t0, inSameDayAs: later)
        center.wake(p.path, .answered(["D-1"]), now: t0.addingTimeInterval(3000))
        let third = center.tick(s, now: later)
        if sameDay {
            #expect(third.isEmpty)
            if Calendar.current.isDate(t0, inSameDayAs: t0.addingTimeInterval(3400)) {
                #expect(center.state(p.path, heartbeat: hb, now: t0.addingTimeInterval(3400)).blocked == .dailyCap(2))
            }
        } else {
            #expect(third == [p.path]); center.runner.wait(p.path)
            return
        }
        center.wake(p.path, .runNow, now: t0.addingTimeInterval(3500))
        #expect(center.tick(s, now: t0.addingTimeInterval(3500)) == [p.path]); center.runner.wait(p.path)
    }

    @Test func theCIBreakerHoldsUntilYouResume() throws {
        let p = try tempDir()
        let center = HeartbeatCenter(runner: HeartbeatRunner(folder: try tempDir(), resolve: ok))
        var hb = Heartbeat(); hb.cooldownMinutes = 0
        let s = ProjectSettings(projects: [.init(root: p.path, factory: true, heartbeat: hb)])
        var t = Date()
        for run in 1...2 {
            center.wake(p.path, .ciFailed(repo: "app", run: "\(run)"), now: t)
            #expect(center.tick(s, now: t) == [p.path]); center.runner.wait(p.path)
            t = t.addingTimeInterval(60)
        }
        center.wake(p.path, .ciFailed(repo: "app", run: "3"), now: t)
        #expect(center.tick(s, now: t).isEmpty)
        #expect(center.state(p.path, heartbeat: hb, now: t).blocked?.waitsForYou == true)
        center.resume(p.path, now: t)
        #expect(center.tick(s, now: t) == [p.path]); center.runner.wait(p.path)
        #expect(center.runner.hold(p.path) == nil)
    }

    /// Every factory has its own CEO (no CEO divides itself over projects): two factories run side by side, each once.
    @Test func everyFactoryRunsItsOwnCEOAndPauseAllStopsThem() throws {
        let a = try tempDir(), b = try tempDir(), state = try tempDir()
        let slow: HeartbeatRunner.Resolve = { _ in Stub.sleep(1) }
        let center = HeartbeatCenter(runner: HeartbeatRunner(folder: state, resolve: slow))
        var s = ProjectSettings(projects: [.init(root: a.path, factory: true), .init(root: b.path, factory: true)])
        center.wake(a.path, .runNow); center.wake(b.path, .runNow)
        #expect(center.tick(s) == [a.path, b.path])          // side by side
        center.wake(a.path, .runNow)
        #expect(center.tick(s).isEmpty)                      // a's own run is still going: one at a time per factory
        center.runner.wait(a.path); center.runner.wait(b.path)
        s.pauseAll = true
        #expect(center.tick(s).isEmpty)
        s.pauseAll = false
        #expect(center.tick(s) == [a.path]); center.runner.wait(a.path)
    }

    @Test(.enabled(if: Stub.hasShell)) func aPlanLimitInTheOutputHoldsTheRuntime() throws {
        let now = Date(timeIntervalSince1970: 1_763_200_000)
        #expect(HeartbeatRunner.planLimit(in: "Claude AI usage limit reached|1763215200", now: now) == Date(timeIntervalSince1970: 1_763_215_200))
        #expect(HeartbeatRunner.planLimit(in: "You've hit your limit · resets 2pm", now: now) == now.addingTimeInterval(3600))
        #expect(HeartbeatRunner.planLimit(in: "All tests passed", now: now) == nil)

        let p = try tempDir()
        let limited: HeartbeatRunner.Resolve = { _ in HeartbeatRunner.Launch(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo 'Claude AI usage limit reached'; exit 1"]) }
        let center = HeartbeatCenter(runner: HeartbeatRunner(folder: try tempDir(), resolve: limited))
        let s = ProjectSettings(projects: [.init(root: p.path, factory: true)])
        center.wake(p.path, .runNow)
        #expect(center.tick(s) == [p.path]); center.runner.wait(p.path)
        #expect(center.runner.planLimit(.claude) != nil && center.runner.planLimit(.codex) == nil)
        if case .planLimit? = center.state(p.path, heartbeat: Heartbeat()).blocked {} else { Issue.record("no plan-limit block") }
    }

    @Test func olderSettingsDecodeWithTheDefaults() throws {
        let json = #"{"projects":[{"root":"/demo/a","pinned":true,"factory":true,"heartbeat":{"days":"everyDay","times":["09:00"]}}]}"#
        let s = try JSONDecoder().decode(ProjectSettings.self, from: Data(json.utf8))
        let hb = try #require(s.entry("/demo/a")?.heartbeat)
        #expect(hb.days == .everyDay && hb.runsPerDay == 6 && hb.cooldownMinutes == 20 && hb.maxTurns == 60 && !s.pauseAll)
    }
}

// setenv and env are a Mac's and Linux's; what a run inherits is the same code on Windows
#if !os(Windows)
struct HeartbeatEnvironmentTests {
    /// A CEO started from inside a Claude Code session (or the desktop app) must not inherit that session.
    @Test func aRunDoesNotInheritAClaudeSession() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("sf-env-\(UUID().uuidString)")
        let project = FileManager.default.temporaryDirectory
        setenv("CLAUDECODE", "1", 1); setenv("CLAUDE_CODE_SESSION_ID", "x", 1); setenv("ANTHROPIC_BASE_URL", "http://localhost:1", 1)
        defer { unsetenv("CLAUDECODE"); unsetenv("CLAUDE_CODE_SESSION_ID"); unsetenv("ANTHROPIC_BASE_URL") }
        let runner = HeartbeatRunner(folder: state, resolve: { _ in
            HeartbeatRunner.Launch(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "env | grep -E '^(CLAUDE|ANTHROPIC_BASE_URL)' | wc -l | tr -d ' '"])
        })
        #expect(runner.start(root: project.path, name: "P", heartbeat: Heartbeat(), reason: .runNow))
        runner.wait(project.path)
        let last = try #require(runner.lastRun(project.path))
        let log = try String(contentsOf: runner.logURL(project.path, started: last.started), encoding: .utf8)
        #expect(log.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
    }
}
#endif

struct HeartbeatAllowlistTests {
    /// The project's .claude/settings.json goes with the run (Claude Code ignores it in a folder not trusted yet);
    /// without one, the run warns.
    @Test func theProjectsAllowlistGoesWithTheRun() throws {
        let fm = FileManager.default
        let with = fm.temporaryDirectory.appendingPathComponent("sf-allow-\(UUID().uuidString)"), without = fm.temporaryDirectory.appendingPathComponent("sf-allow-\(UUID().uuidString)")
        try fm.createDirectory(at: with.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try fm.createDirectory(at: without, withIntermediateDirectories: true)
        try "{}".write(wholeTo: with.appendingPathComponent(".claude/settings.json"))
        nonisolated(unsafe) var seen: [String: URL?] = [:]
        let lock = NSLock()
        let runner = HeartbeatRunner(folder: fm.temporaryDirectory.appendingPathComponent("sf-allow-state-\(UUID().uuidString)"), resolve: { r in
            lock.lock(); seen[r.prompt.contains(with.path) ? "with" : "without"] = r.settings; lock.unlock()
            return Stub.succeed
        })
        #expect(runner.start(root: with.path, name: "A", heartbeat: Heartbeat(), reason: .runNow)); runner.wait(with.path)
        #expect(runner.start(root: without.path, name: "B", heartbeat: Heartbeat(), reason: .runNow)); runner.wait(without.path)
        #expect(seen["with"]??.lastPathComponent == "settings.json" && seen["without"]! == nil)
        #expect(runner.lastRun(with.path)?.warning == nil && runner.lastRun(without.path)?.warning != nil)
        // the real launch passes it with --settings (its arguments; CI has no claude or codex installed)
        let launch = HeartbeatRunner.arguments(.init(runtime: .claude, prompt: "p", maxTurns: 5, settings: URL(fileURLWithPath: "/x/.claude/settings.json")))
        #expect(launch.suffix(2) == ["--settings", "/x/.claude/settings.json"])
        // Codex works in a folder that is not a git repo of its own (a factory's main folder, the Server room)
        let codex = HeartbeatRunner.arguments(.init(runtime: .codex, prompt: "p", maxTurns: 5, settings: nil))
        #expect(codex.contains("--skip-git-repo-check"))
    }
}

struct HeartbeatInterruptedTests {
    /// The app closed during a run: once its process is gone, the run is closed off instead of "running" forever.
    @Test func aRunWhoseProcessIsGoneIsClosedOff() throws {
        let fm = FileManager.default
        let state = fm.temporaryDirectory.appendingPathComponent("sf-int-\(UUID().uuidString)"), project = fm.temporaryDirectory
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
        let started = Date(timeIntervalSince1970: 1_763_200_000)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        struct S: Encodable { var runs: [HeartbeatRun] }
        let runner = HeartbeatRunner(folder: state, resolve: { _ in nil })
        try enc.encode(S(runs: [HeartbeatRun(started: started, reason: .runNow, outcome: .running)])).write(to: runner.stateURL(project.path))
        // a live process holds the lock: still running
        try Stub.whileAnotherProcessLives { pid in
            try "\(pid)".write(wholeTo: runner.lockURL(project.path))
            #expect(runner.lastRun(project.path)?.outcome == .running)
        }
        // the process is gone
        try "999999".write(wholeTo: runner.lockURL(project.path))
        let last = try #require(runner.lastRun(project.path))
        #expect(last.outcome == .failed && last.detail?.contains("closed") == true)
        #expect(!fm.fileExists(atPath: runner.lockURL(project.path).path))
    }
}

/// Your ideas for a factory's CEO (factory/ideas/): written by the app, read back, never overwritten.
struct IdeaInboxTests {
    @Test func anIdeaIsWrittenReadBackAndWakesTheCEO() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sf-idea-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("factory/ideas"), withIntermediateDirectories: true)
        // an idea already there (the CEO's or an older one) keeps its file; the next gets the next id
        try "---\nid: I-0004\ntitle: Old\nstatus: taken\ndecision: D-0002\n---\n\nOld.\n\n## CEO\nTaken.\n"
            .write(wholeTo: root.appendingPathComponent("factory/ideas/I-0004-old.md"))
        let id = try IdeaInbox.send(root: root.path, text: "  Hints that explain why\nnot just where  ")
        #expect(id == "I-0005")
        #expect(throws: IdeaInbox.Failure.self) { try IdeaInbox.send(root: root.path, text: "   ") }
        let f = FactoryFinder.read(root: root.path)
        #expect(f.ideas.map(\.id) == ["I-0004", "I-0005"])
        let new = try #require(f.ideas.last)
        #expect(new.status == .new && new.title == "Hints that explain why" && new.text == "Hints that explain why\nnot just where" && new.decision == nil)
        #expect(f.ideas.first?.reply == "Taken." && f.problems.isEmpty)
        // without contract.yml a factory is version 1: no ideas box; version 2 takes ideas
        #expect(f.contract == nil && f.contractVersion == 1 && !f.takesIdeas)
        try "contract: meatproxy-factory\nversion: 2\n".write(wholeTo: root.appendingPathComponent("factory/contract.yml"))
        let v2 = FactoryFinder.read(root: root.path)
        #expect(v2.contractVersion == 2 && v2.takesIdeas && !v2.newerContract)
        #expect(FactoryText.contract("contract: something-else\nversion: 2") == nil)
        #expect(FactoryText.contract("contract: meatproxy-factory\nversion: 9").map { $0 > FactoryContract.current } == true)
        // a folder that is missing is made
        let bare = fm.temporaryDirectory.appendingPathComponent("sf-idea-\(UUID().uuidString)")
        try fm.createDirectory(at: bare, withIntermediateDirectories: true)
        #expect(try IdeaInbox.send(root: bare.path, text: "First") == "I-0001")
    }

    @Test func ideasWaitForTheirWindowAndDoNotPushAsideAnswers() throws {
        let center = HeartbeatCenter(runner: HeartbeatRunner(folder: FileManager.default.temporaryDirectory.appendingPathComponent("sf-ideaw-\(UUID().uuidString)"), resolve: { _ in nil }))
        let t0 = Date()
        center.wake("/p", .idea(["I-0001"]), now: t0)
        center.wake("/p", .idea(["I-0002"]), now: t0.addingTimeInterval(30))
        #expect(center.pending["/p"]?.reason == .idea(["I-0001", "I-0002"]))
        center.wake("/q", .answered(["D-1"]), now: t0)
        center.wake("/q", .idea(["I-0001"]), now: t0)
        #expect(center.pending["/q"]?.reason == .answered(["D-1"]))
        center.wake("/q", .runNow, now: t0)
        #expect(center.pending["/q"]?.reason == .runNow)
    }
}

/// Your mandate for a factory (contract v3, D56).
struct MandateTests {
    @Test func theMandateRoundTripsAndPresetsHold() {
        var m = FactoryMandate()
        #expect(m.mode(.ship) == .ask && m.autonomyLevel == .assistant)
        m.set(level: .hybrid)
        #expect(m.mode(.bugs) == .notify && m.mode(.ship) == .ask && m.autonomyLevel == .hybrid)
        m.set(level: .dark)
        #expect(m.mode(.ship) == .notify && m.mode(.spend) == .ask && m.mode(.store) == .ask)
        // an item changed by hand makes it Custom, and it keeps the rest
        m.level = .custom; m.items[.spend] = .off
        m.role = .handsOn; m.quietHours = "22:00-07:00"; m.briefingLanguage = "nl"; m.notes = "Never touch \"payments\".\nAsk before onboarding."
        let back = FactoryMandate.parse(m.yaml)
        #expect(back == m)
        #expect(back.summary == "Works along · Custom · 3 preferences")
        #expect(FactoryMandate.parse("level: hybrid\nitems:\n  ship: notify\n").mode(.ship) == .ask)   // a preset wins over stray items
        #expect(FactoryMandate.parse("nonsense: yes").level == .assistant)
        // its own ideas: a question in Hybrid, its own call in Dark, and the file explains every item to the CEO
        #expect(FactoryMandate.preset(.hybrid)[.propose] == .ask && FactoryMandate.preset(.dark)[.propose] == .notify)
        #expect(FactoryMandate().yaml.contains("propose: ask") && FactoryMandate().yaml.contains("# come up with ideas of its own"))
        // a mandate written before propose existed reads it as ask
        #expect(FactoryMandate.parse("level: custom\nitems:\n  plan: notify\n").mode(.propose) == .ask)
    }

    @Test func onlyAVersion3FactoryTakesItsMandate() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sf-mandate-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("factory"), withIntermediateDirectories: true)
        var m = FactoryMandate(); m.set(level: .dark)
        try MandateFile.write(m, root: root.path)
        try "level: assistant\ngates:\n  plan: ask\n".write(wholeTo: root.appendingPathComponent("factory/autonomy.yml"))
        try "contract: meatproxy-factory\nversion: 2\n".write(wholeTo: root.appendingPathComponent("factory/contract.yml"))
        #expect(!FactoryFinder.read(root: root.path).takesMandate)
        #expect(FactoryFinder.read(root: root.path).autonomy?.level == .assistant)       // v2: the CEO's autonomy.yml
        try "contract: meatproxy-factory\nversion: 3\n".write(wholeTo: root.appendingPathComponent("factory/contract.yml"))
        let f = FactoryFinder.read(root: root.path)
        #expect(f.takesMandate && f.mandate?.level == .dark && f.autonomy?.level == .dark)  // v3: your mandate sets it
        #expect(Fixture.factory().takesMandate && Fixture.factory().mandate?.level == .hybrid)
        // your ideas need no yes: one taken becomes a workstream, and the mandate has no item for them
        #expect(Fixture.factory().ideas.first { $0.status == .taken }?.workstream == "W-004")
        #expect(!FactoryMandate.Item.allCases.map(\.rawValue).contains("plan"))
    }
}

/// The terminal's commands (D57): only checked parts, never through a shell.
struct TerminalCommandTests {
    private let cli: (String) -> String? = { "/opt/homebrew/bin/\($0)" }

    @Test func takingOverResumesTheSessionWhereItStarted() {
        let s = Session(id: "d1d2e3f4-aaaa-bbbb-cccc-123456789012", provider: .claude, cwd: NSTemporaryDirectory(), title: "Fix the timer", lastAt: Date(), turnOpen: false)
        let c = TerminalCommand.resume(s, cli: cli)
        #expect(c?.executable == "/opt/homebrew/bin/claude" && c?.args == ["--resume", s.id] && c?.cwd == NSTemporaryDirectory())
        var codex = s; codex.provider = .chatgpt
        #expect(TerminalCommand.resume(codex, cli: cli)?.args == ["resume", s.id])
        var bad = s; bad.id = "x; rm -rf ~"
        #expect(TerminalCommand.resume(bad, cli: cli) == nil)
        #expect(TerminalCommand.resume(s, cli: { _ in nil }) == nil)                        // no CLI, no tab
        var gone = s; gone.cwd = "/no/such/folder"
        #expect(TerminalCommand.resume(gone, cli: cli)?.cwd == NSHomeDirectory())
    }

    @Test func sshAndLogsTakeOnlyPlainParts() {
        #expect(TerminalCommand.ssh("ops@web-01.example.com", name: "web-01")?.args == ["ops@web-01.example.com"])
        #expect(TerminalCommand.ssh("-oProxyCommand=evil", name: "x") == nil)
        #expect(TerminalCommand.ssh("host; id", name: "x") == nil)
        #expect(TerminalCommand.follow("/no/such.log", title: "x") == nil)
        let env = TerminalCommand.environment(["CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "s", "ANTHROPIC_BASE_URL": "http://x", "PATH": "/x"])
        #expect(!env.contains { $0.hasPrefix("CLAUDE") || $0.hasPrefix("ANTHROPIC_BASE_URL") } && env.contains("TERM=xterm-256color"))
    }
}

/// Taking over in the terminal (D57).
struct TakeOverTests {
    @Test func takingOverStopsTheRunAndHoldsTheHeartbeat() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sf-take-\(UUID().uuidString)"), state = fm.temporaryDirectory.appendingPathComponent("sf-take-state-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let slow: HeartbeatRunner.Resolve = { _ in Stub.sleep(30) }
        let center = HeartbeatCenter(runner: HeartbeatRunner(folder: state, resolve: slow))
        let s = ProjectSettings(projects: [.init(root: root.path, factory: true)])
        center.wake(root.path, .runNow)
        #expect(center.tick(s) == [root.path])
        center.takeOver(root.path)
        center.runner.wait(root.path)
        let last = try #require(center.runner.lastRun(root.path))
        #expect(last.outcome == .takenOver && last.detail == "you took over in the terminal")
        // while it is yours, nothing starts, not even Run now
        center.wake(root.path, .runNow)
        #expect(center.tick(s).isEmpty)
        #expect(center.state(root.path, heartbeat: Heartbeat()).blocked == .takenOver)
        center.handBack(root.path)
        #expect(center.tick(s) == [root.path]); center.runner.stop(root.path, because: "test over"); center.runner.wait(root.path)
    }
}
