import Foundation
import Testing
@testable import FactoryCollector
@testable import FactoryCore

/// A Dark Software Factory read from its `factory/` files, and answering its questions. Fictional data only.
struct FactoryTests {
    private let fm = FileManager.default

    private func tempDir() throws -> URL {
        let u = fm.temporaryDirectory.appendingPathComponent("sf-factory-\(UUID().uuidString)")
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Writes the demo factory's files under `root`.
    private func writeFixture(at root: URL, now: Date = Date()) throws {
        for (rel, text) in Fixture.factoryFiles(now: now) {
            let u = root.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(wholeTo: u)
        }
    }

    private static let open = """
    ---
    id: D-0001
    title: Fix the hint that does nothing on a solved cell?   # the yes/no question, one sentence
    kind: plan            # plan | ship | store | promote | stop | other
    gate: plan            # plan | ship | store | always-ask
    status: open          # open | yes | no | expired | withdrawn
    workstream: W-001     # optional
    replaces: null        # D-id this one replaces after a "no"
    asked: 2026-11-16T07:05:00+01:00
    answered: null        # ISO timestamp when status left open
    ---

    ## Why
    Two or three sentences: the problem and what the factory wants to do.

    ## Evidence
    - [Crash report](https://errors.example.com/issues/12)
    - https://github.com/example/app/pull/7

    ## On yes
    What happens next.

    ## On no
    What the CEO will do instead.

    ## Answer

    """

    private static let at = ISO8601DateFormatter().date(from: "2026-11-16T08:30:00Z")!
    private static let cet = TimeZone(identifier: "Europe/Amsterdam")!

    // MARK: reading

    @Test func readsTheDemoFactory() throws {
        let root = try tempDir()
        try writeFixture(at: root)
        let f = FactoryFinder.read(root: root.path)
        #expect(f.problems.isEmpty)
        #expect(f.workstreams.map(\.id) == ["W-001", "W-002", "W-003", "W-004", "W-005", "W-006"])
        #expect(f.activeWorkstreams.count == 5)
        #expect(f.openDecisions.map(\.id) == ["D-0007", "D-0008", "D-0010", "D-0011"])
        #expect(f.readyToRelease.map(\.id) == ["W-006"])
        #expect(f.autonomy?.level == .hybrid)
        #expect(f.autonomy?.gates.map { "\($0.name)=\($0.notify ? "notify" : "ask")/\($0.streak)" } == ["plan=notify/5", "ship=ask/5", "store=ask/0"])
        #expect(f.autonomy?.paused == false)
        // the latest of two briefings, its three sections
        let b = try #require(f.briefing)
        #expect(b.briefing.count == 4)
        #expect(b.needsYou.count == 4)
        #expect(b.delivered.first?.hasPrefix("Undo after a hint") == true)
        let d = try #require(f.decision(id: "D-0007"))
        #expect(d.kind == "ship" && d.gate == "ship" && d.workstream == "W-002")
        #expect(d.links.map(\.title) == ["PR #41", "CI run, all green"])
    }

    @Test func backTransitionsComeFromTheLog() throws {
        let f = Fixture.factory()
        let w2 = try #require(f.workstreams.first { $0.id == "W-002" }), w3 = try #require(f.workstreams.first { $0.id == "W-003" })
        #expect(w2.backSteps.count == 1)
        #expect(w2.backSteps.first?.from == .test && w2.backSteps.first?.phase == .build)
        #expect(!w2.wentBack)                 // it moved on to ship since
        #expect(w3.wentBack)                  // the latest step was test → build
        #expect(w3.reached == WorkPhase.test.step)
        #expect(WorkPhase.ship.room == .deploy && WorkPhase.plan.room == .planning)
    }

    @Test func stopOnLineOnePausesTheFactory() {
        let a = FactoryText.autonomy("STOP\nlevel: dark\ngates:\n  plan: notify\n  ship: notify\n  store: notify\n")
        #expect(a.paused)
        #expect(a.level == .dark)
        let derived = FactoryText.autonomy("gates:\n  plan: notify # earned\n  ship: ask\nstreaks:\n  plan: 6\n")
        #expect(derived.level == .hybrid && !derived.paused && derived.gates.first?.streak == 6)
    }

    @Test func aBrokenFileIsAProblemNotACrash() {
        let f = FactoryText.factory(root: "/demo/x", files: [
            "factory/decisions/D-0009-broken.md": "no front matter here",
            "factory/workstreams/W-009-broken.md": "---\nid: W-009\nphase: sideways\n---\n",
            "factory/decisions/D-0001-ok.md": Self.open,
        ])
        #expect(f.decisions.map(\.id) == ["D-0001"])
        #expect(Set(f.problems) == ["D-0009-broken.md", "W-009-broken.md"])
    }

    @Test func aHashInATitleIsNotAComment() {
        #expect(FactoryText.value(" Support C# input?   # the question") == "Support C# input?")
        #expect(FactoryText.value(" \"Quoted: yes\"") == "Quoted: yes")
    }

    // MARK: answering

    @Test func answeringChangesOnlyStatusAnsweredAndAnswer() throws {
        let out = try DecisionAnswer.answered(Self.open, yes: true, note: "Yes, and add a test for it.", at: Self.at, timeZone: Self.cet)
        let before = Self.open.components(separatedBy: "\n"), after = out.components(separatedBy: "\n")
        #expect(after.count == before.count + 1)          // the note fills the empty Answer section
        let changed = zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(changed.map { before[$0] }.allSatisfy { $0.hasPrefix("status:") || $0.hasPrefix("answered:") || $0.isEmpty })
        #expect(after.contains("status: yes           # open | yes | no | expired | withdrawn"))
        #expect(after.contains("answered: 2026-11-16T09:30:00+01:00 # ISO timestamp when status left open"))
        let d = try #require(FactoryText.decision(out, file: "x"))
        #expect(d.status == .yes)
        #expect(d.answered == Self.at)
        #expect(d.answer == "Yes, and add a test for it.")
        #expect(d.why == "Two or three sentences: the problem and what the factory wants to do.")
        #expect(out.hasSuffix("\n"))
    }

    @Test func noWithoutANoteLeavesTheAnswerSectionAlone() throws {
        let out = try DecisionAnswer.answered(Self.open, yes: false, note: "  ", at: Self.at, timeZone: Self.cet)
        #expect(out.components(separatedBy: "\n").count == Self.open.components(separatedBy: "\n").count)
        #expect(FactoryText.decision(out, file: "x")?.status == DecisionStatus.no)
        #expect(out.hasSuffix("## Answer\n"))
    }

    @Test func aNoteReplacesAPlaceholderAndKeepsLaterSections() throws {
        let text = Self.open.replacingOccurrences(of: "## Answer\n", with: "## Answer\nMarcel's note, if any.\n\n## Result\nFilled in by the CEO.\n")
        let out = try DecisionAnswer.answered(text, yes: false, note: "No, too risky before the release.", at: Self.at, timeZone: Self.cet)
        #expect(out.contains("## Answer\nNo, too risky before the release.\n\n## Result\nFilled in by the CEO.\n"))
        #expect(!out.contains("Marcel's note"))
    }

    @Test func aMissingAnswerSectionAndAnsweredLineAreAdded() throws {
        let text = "---\nid: D-0002\ntitle: Ship it?\nstatus: open\n---\n\n## Why\nBecause.\n"
        let out = try DecisionAnswer.answered(text, yes: true, note: "Go.", at: Self.at, timeZone: Self.cet)
        #expect(out == "---\nid: D-0002\ntitle: Ship it?\nstatus: yes\nanswered: 2026-11-16T09:30:00+01:00\n---\n\n## Why\nBecause.\n\n## Answer\nGo.\n")
    }

    @Test func answeringWritesTheFileAtomically() throws {
        let dir = try tempDir(), url = dir.appendingPathComponent("D-0001-hint.md")
        try Self.open.write(wholeTo: url)
        try DecisionAnswer.answer(url, yes: true, note: nil, at: Self.at, timeZone: Self.cet)
        let d = try #require(FactoryText.decision(try String(contentsOf: url, encoding: .utf8), file: "x"))
        #expect(d.status == .yes)
        // no temporary file is left behind
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["D-0001-hint.md"])
    }

    @Test func anAlreadyAnsweredQuestionIsRefusedAndUntouched() throws {
        let dir = try tempDir(), url = dir.appendingPathComponent("D-0001-hint.md")
        let answered = Self.open.replacingOccurrences(of: "status: open  ", with: "status: no    ")
        try answered.write(wholeTo: url)
        #expect(throws: DecisionAnswer.Failure.notOpen("no")) { try DecisionAnswer.answer(url, yes: true, note: "changed my mind", at: Self.at) }
        #expect(try String(contentsOf: url, encoding: .utf8) == answered)
        // answering twice: the second is refused
        let dir2 = try tempDir(), url2 = dir2.appendingPathComponent("D-0001-hint.md")
        try Self.open.write(wholeTo: url2)
        try DecisionAnswer.answer(url2, yes: true, note: nil, at: Self.at)
        #expect(throws: DecisionAnswer.Failure.notOpen("yes")) { try DecisionAnswer.answer(url2, yes: false, note: nil, at: Self.at) }
    }

    @Test func aMalformedFileIsRefusedAndUntouched() throws {
        let dir = try tempDir()
        for (k, text) in ["no front matter", "---\nid: D-1\ntitle: Ship?\n---\nno status", "---\nid: D-1\ntitle: Ship?\nstatus: maybe\n---\n",
                          "---\nid: D-1\nstatus: open\n"].enumerated() {
            let url = dir.appendingPathComponent("D-000\(k)-bad.md")
            try text.write(wholeTo: url)
            #expect(throws: DecisionAnswer.Failure.self) { try DecisionAnswer.answer(url, yes: true, note: "x", at: Self.at) }
            #expect(try String(contentsOf: url, encoding: .utf8) == text)
        }
        #expect(throws: DecisionAnswer.Failure.self) { try DecisionAnswer.answer(dir.appendingPathComponent("missing.md"), yes: true, note: nil) }
    }

    // MARK: on the campus

    @Test func aFactoryHasAFloorWithoutSessionsAndItsQuestionsNeedYou() throws {
        let home = try tempDir(), root = home.appendingPathComponent("Projects/Tuinstra.DEV/pebble")
        try writeFixture(at: root)
        let w = Collector(home: home, resolver: ProjectResolver(home: home.path)).world(factories: [root.path])
        let p = try #require(w.projects.first { $0.root == root.path })
        #expect(p.provider == .claude && p.name == "Pebble" && p.sessions.isEmpty)
        #expect(p.factory?.openDecisions.count == 4)
        #expect(p.waits(now: w.now))
        // oldest first: the release has waited two days
        #expect(w.needsYou.map(\.id) == ["release:\(p.id)", "decision:\(p.id)/D-0007", "decision:\(p.id)/D-0008", "decision:\(p.id)/D-0010", "decision:\(p.id)/D-0011"])
        #expect(w.decision(project: p.id, "D-0008")?.decision.kind == "promote")
    }

    @Test func onlyASwitchedOnProjectIsAFactory() throws {
        let home = try tempDir(), root = home.appendingPathComponent("Projects/pebble"), other = home.appendingPathComponent("Projects/shopfront")
        try writeFixture(at: root)
        try fm.createDirectory(at: other.appendingPathComponent("code"), withIntermediateDirectories: true)
        let c = Collector(home: home, resolver: ProjectResolver(home: home.path))
        // a factory/ folder alone does not make one
        #expect(c.world().projects.isEmpty)
        #expect(c.world().needsYou.isEmpty)
        // switched on without any factory files: a floor with an empty factory, and nothing is created in the project
        let w = c.world(factories: [other.path])
        let p = try #require(w.projects.first { $0.root == other.path })
        #expect(p.factory?.isEmpty == true)
        #expect(!fm.fileExists(atPath: other.appendingPathComponent("factory").path))
        #expect(c.world(factories: [root.path]).projects.first?.factory?.isEmpty == false)
    }

    @Test func theSwitchedOnFactoriesAreKeptInTheSettings() throws {
        let store = FactorySettingsStore(url: try tempDir().appendingPathComponent("Software Factory/factories.json"))
        #expect(store.load().isEmpty)
        try store.save(["/demo/pebble", "/demo/harbor"])
        #expect(store.load() == ["/demo/pebble", "/demo/harbor"])
        #expect(try String(contentsOf: store.url, encoding: .utf8).contains("\"/demo/pebble\""))
    }

    @Test func aScheduledCeoRunFromAScratchFolderIsTheFactorys() throws {
        let home = try tempDir(), root = home.appendingPathComponent("Projects/Tuinstra.DEV/pebble")
        try writeFixture(at: root)
        let scratch = home.appendingPathComponent("Library/Application Support/Claude/scratch-workspaces/abc/scratch-1").path
        let dir = home.appendingPathComponent(".claude/projects/scratch")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date(), f = ISO8601DateFormatter()
        func line(_ o: [String: Any]) throws -> Data { var d = try JSONSerialization.data(withJSONObject: o); d.append(10); return d }
        // the prompt is an injected block (it starts with <), the cd happens in the shell; the file keeps the scratch cwd
        var run = try line(["type": "user", "cwd": scratch, "timestamp": f.string(from: now.addingTimeInterval(-60)),
                            "message": ["content": "<scheduled-task name=\"pebble-ceo\">You are the CEO. First `cd \(root.path)` and work from there.</scheduled-task>"]])
        run.append(try line(["type": "assistant", "cwd": scratch, "timestamp": f.string(from: now.addingTimeInterval(-30)),
                             "message": ["stop_reason": "end_turn", "content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "cd \(root.path) && ls factory"]]]]]))
        try run.write(to: dir.appendingPathComponent("11111111-2222-3333-4444-555555555555.jsonl"))
        // a chat that only mentions a longer folder name stays a chat
        let other = try line(["type": "user", "cwd": home.path, "timestamp": f.string(from: now.addingTimeInterval(-90)),
                              "message": ["content": "Look at \(root.path)-old please"]])
        try other.write(to: dir.appendingPathComponent("66666666-2222-3333-4444-555555555555.jsonl"))

        let w = Collector(home: home, resolver: ProjectResolver(home: home.path)).world(now: now, factories: [root.path])
        let p = try #require(w.projects.first { $0.root == root.path })
        #expect(p.sessions.map(\.id) == ["11111111-2222-3333-4444-555555555555"])
        #expect(p.sessions.first?.cwd == scratch)          // the resume command still opens it where it lives
        #expect(p.factory != nil)
        #expect(w.projects.contains { $0.isChat && $0.sessions.first?.id == "66666666-2222-3333-4444-555555555555" })
    }
}

/// The settings folder moved with the brand (D45): "Software Factory" becomes "Meatproxy", once, and never over a newer one.
struct AppSupportTests {
    @Test func theOldSettingsFolderMovesOnce() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sf-support-\(UUID().uuidString)")
        let old = base.appendingPathComponent("Software Factory")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try "{\"servers\":[]}".write(wholeTo: old.appendingPathComponent("servers.json"))
        #expect(AppSupport.migrateLegacyFolder(in: base))
        #expect(fm.fileExists(atPath: base.appendingPathComponent("Meatproxy/servers.json").path))
        #expect(!fm.fileExists(atPath: old.path))
        // a second start does nothing; an old folder next to a new one is left alone
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        #expect(!AppSupport.migrateLegacyFolder(in: base))
        #expect(fm.fileExists(atPath: old.path))
    }
}
