import Foundation
import Testing
@testable import FactoryCollector
@testable import FactoryCore

/// The collector is the part that must match live.py. These tests pin its behaviour with small, fictional files.
struct CollectorTests {
    private func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("sf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func jsonl(_ objects: [[String: Any]]) throws -> Data {
        var d = Data()
        for o in objects { d.append(try JSONSerialization.data(withJSONObject: o)); d.append(10) }
        return d
    }

    // MARK: project = git root (D27)

    @Test func gitRootFromASubfolderOutsideProjects() throws {
        let home = try tempDir(), repo = home.appendingPathComponent("Code/shopfront")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src/app"), withIntermediateDirectories: true)
        let k = ProjectResolver(home: home.path).resolve(repo.appendingPathComponent("src/app").path)
        #expect(k.root == repo.path)
        #expect(k.name == "Shopfront")
        #expect(!k.isChat)
    }

    @Test func everythingUnderAProjectFolderIsOneProject() throws {
        let home = try tempDir(), proj = home.appendingPathComponent("Projects/shopfront")
        for sub in ["code/web/.git", "code/apps/.git", "assets/board"] { try FileManager.default.createDirectory(at: proj.appendingPathComponent(sub), withIntermediateDirectories: true) }
        let r = ProjectResolver(home: home.path)
        for sub in ["code/web/src", "code/apps", "assets/board", ""] { #expect(r.resolve(proj.appendingPathComponent(sub).path).root == proj.path) }
        let td = home.appendingPathComponent("Projects/Tuinstra.DEV/tracker/code/api")
        try FileManager.default.createDirectory(at: td, withIntermediateDirectories: true)
        #expect(r.resolve(td.path).root == home.appendingPathComponent("Projects/Tuinstra.DEV/tracker").path)
        #expect(r.resolve(td.path).name == "Tracker")
    }

    @Test func aSessionStaysOnTheFloorItStartedOn() throws {
        let dir = try tempDir(), file = dir.appendingPathComponent("eeeeeeee-2222-3333-4444-555555555555.jsonl")
        try jsonl([
            ["type": "user", "cwd": "/demo/shopfront", "timestamp": "2026-11-14T10:00:00Z", "message": ["content": "Start here"]],
            ["type": "assistant", "cwd": "/demo/shopfront/assets/board", "timestamp": "2026-11-14T10:05:00Z", "message": ["stop_reason": "end_turn", "content": []]],
        ]).write(to: file)
        let r = SessionReader(url: file, provider: .claude)
        try r.read()
        #expect(try #require(r.session()).cwd == "/demo/shopfront")
    }

    /// D83: a chat in the Claude app says so in its file; you answer it there, not by resuming it in a terminal.
    @Test func aSessionKnowsItRunsInTheClaudeApp() throws {
        let dir = try tempDir()
        for (name, entry, inApp) in [("aaaaaaaa-2222-3333-4444-555555555555", "claude-desktop", true), ("bbbbbbbb-2222-3333-4444-555555555555", "cli", false)] {
            let file = dir.appendingPathComponent(name + ".jsonl")
            try jsonl([
                ["type": "user", "cwd": "/demo/shopfront", "entrypoint": entry, "timestamp": "2026-11-14T10:00:00Z", "message": ["content": "Start here"]],
                ["type": "assistant", "cwd": "/demo/shopfront", "entrypoint": entry, "timestamp": "2026-11-14T10:05:00Z", "message": ["stop_reason": "end_turn", "content": []]],
            ]).write(to: file)
            let r = SessionReader(url: file, provider: .claude)
            try r.read()
            let s = try #require(r.session())
            #expect(s.entrypoint == entry)
            #expect(s.inClaudeApp == inApp)
        }
    }

    @Test func worktreeCountsAsItsRepo() throws {
        let home = try tempDir(), repo = home.appendingPathComponent("Code/harbor-api"), wt = home.appendingPathComponent("worktrees/harbor-fix")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/worktrees/harbor-fix"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        try "gitdir: \(repo.path)/.git/worktrees/harbor-fix\n".write(wholeTo: wt.appendingPathComponent(".git"))
        let k = ProjectResolver(home: home.path).resolve(wt.path)
        #expect(k.root == repo.path)
        #expect(k.name == "Harbor API")
    }

    @Test func folderWithoutGitAndHomeAsChat() throws {
        let home = try tempDir(), plain = home.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let r = ProjectResolver(home: home.path)
        #expect(r.resolve(plain.path).root == plain.path)
        #expect(r.resolve(home.path).isChat)
        #expect(r.resolve("~").isChat)
    }

    // MARK: Claude Code sessions

    @Test func aFinishedTurnWaitsOnlyWhenItAsks() throws {
        let dir = try tempDir(), file = dir.appendingPathComponent("11111111-2222-3333-4444-555555555555.jsonl")
        try jsonl([
            ["type": "user", "cwd": "/demo/shopfront", "gitBranch": "fix/flake", "timestamp": "2026-11-14T10:00:00.000Z",
             "message": ["content": "Fix the flaky checkout test"]],
            ["type": "assistant", "timestamp": "2026-11-14T10:01:00.000Z",
             "message": ["model": "claude-opus", "content": [["type": "tool_use", "id": "t1", "name": "Edit", "input": ["file_path": "/demo/shopfront/Checkout.swift"]]]]],
            ["type": "assistant", "timestamp": "2026-11-14T10:02:00.000Z",
             "message": ["content": [["type": "tool_use", "id": "t2", "name": "Bash", "input": ["command": "cd /demo && npm test"]]]]],
            ["type": "assistant", "timestamp": "2026-11-14T10:03:00.000Z", "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": "Done"]]]],
        ]).write(to: file)
        let r = SessionReader(url: file, provider: .claude)
        try r.read()
        let s = try #require(r.session())
        #expect(s.cwd == "/demo/shopfront")
        #expect(s.branch == "fix/flake")
        #expect(s.title == "Fix the flaky checkout test")
        #expect(s.activities.map(\.kind) == [.prompt, .edit, .test, .turnEnd])
        #expect(s.activities[1].text == "edited Checkout.swift")
        #expect(!s.turnOpen)
        #expect(s.lastSaid == "Done")
        // it ended without asking anything: done, not waiting (D25)
        #expect(s.state(now: s.lastAt.addingTimeInterval(60)) == .done)
        // a turn that ends with a question waits for you, up to a day
        var asks = s; asks.lastSaid = "The test passes now.\n\nShall I open the PR, or do you want the diff first?"
        #expect(asks.state(now: s.lastAt.addingTimeInterval(2 * 3600)) == .waiting)
        #expect(asks.state(now: s.lastAt.addingTimeInterval(25 * 3600)) == .done)
        // a "?" inside code is no question
        asks.lastSaid = "Fixed the regex:\n\n```\na?b\n```\n\nAll green."
        #expect(asks.state(now: s.lastAt.addingTimeInterval(60)) == .done)
    }

    /// The heartbeat's own CEO run ends its turn with questions, but those reach you as decisions: it never waits (D47).
    @Test func aHeartbeatRunNeverWaitsForYou() throws {
        let dir = try tempDir(), file = dir.appendingPathComponent("21111111-2222-3333-4444-555555555555.jsonl")
        try jsonl([
            ["type": "user", "cwd": "/demo/pebble-puzzles", "timestamp": "2026-11-14T10:00:00.000Z",
             "message": ["content": HeartbeatRunner.prompt(root: "/demo/pebble-puzzles", name: "Pebble Puzzles", reason: .runNow)]],
            ["type": "assistant", "timestamp": "2026-11-14T10:03:00.000Z", "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": "1. Ship it?"]]]],
        ]).write(to: file)
        let r = SessionReader(url: file, provider: .claude)
        try r.read()
        let s = try #require(r.session())
        #expect(s.title == "CEO run (heartbeat)")
        #expect(s.state(now: s.lastAt.addingTimeInterval(60)) == .done)
        // one CEO per project: a later run is the same person, and the floor shows only the latest run
        var later = s; later.id = "later"; later.lastAt = s.lastAt.addingTimeInterval(3600)
        let dev = Session(id: "dev", provider: .claude, cwd: "/demo/pebble-puzzles", title: "Fix the timer", lastAt: s.lastAt, turnOpen: true)
        let w = WorldBuilder.build([s, later, dev], now: later.lastAt) { ProjectKey(root: $0, name: "Pebble", isChat: false) }
        let floor = try #require(w.projects.first)
        #expect(floor.sessions.map(\.id) == ["later", "dev"])
        #expect(floor.role(of: later) == .ceo && later.persona.name == s.persona.name)
    }

    @Test func failedCommandInAnOpenTurnIsStuck() throws {
        let dir = try tempDir(), file = dir.appendingPathComponent("aaaaaaaa-2222-3333-4444-555555555555.jsonl")
        try jsonl([
            ["type": "user", "cwd": "/demo/harbor-api", "timestamp": "2026-11-14T10:00:00Z", "message": ["content": "Rate-limit the API"]],
            ["type": "assistant", "timestamp": "2026-11-14T10:00:10Z",
             "message": ["content": [["type": "tool_use", "id": "t9", "name": "Bash", "input": ["command": "swift test"]]]]],
            ["type": "user", "timestamp": "2026-11-14T10:00:20Z",
             "message": ["content": [["type": "tool_result", "tool_use_id": "t9", "is_error": true, "content": "1 failure"]]]],
        ]).write(to: file)
        let r = SessionReader(url: file, provider: .claude)
        try r.read()
        let s = try #require(r.session())
        #expect(s.turnOpen)
        #expect(s.activities.last?.failed == true)
        #expect(s.state(now: s.lastAt.addingTimeInterval(30)) == .stuck)
    }

    @Test func toolUseMeansTheTurnIsStillOpen() throws {
        let dir = try tempDir(), file = dir.appendingPathComponent("dddddddd-2222-3333-4444-555555555555.jsonl")
        try jsonl([
            ["type": "assistant", "cwd": "/demo/shopfront", "timestamp": "2026-11-14T10:00:00Z", "message": ["stop_reason": "end_turn", "content": []]],
            ["type": "assistant", "timestamp": "2026-11-14T10:10:00Z",
             "message": ["content": [["type": "tool_use", "id": "t3", "name": "Read", "input": ["file_path": "/demo/a.swift"]]]]],
        ]).write(to: file)
        let r = SessionReader(url: file, provider: .claude)
        try r.read()
        let s = try #require(r.session())
        #expect(s.turnOpen)
        #expect(s.state(now: s.lastAt.addingTimeInterval(20)) == .working)
    }

    @Test func readsOnlyAppendedLinesOnTheNextPoll() throws {
        let dir = try tempDir(), file = dir.appendingPathComponent("bbbbbbbb-2222-3333-4444-555555555555.jsonl")
        try jsonl([["type": "user", "cwd": "/demo/tide", "timestamp": "2026-11-14T10:00:00Z", "message": ["content": "Sync notes"]]]).write(to: file)
        let r = SessionReader(url: file, provider: .claude)
        try r.read()
        #expect(r.items.count == 1)
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        try h.write(contentsOf: jsonl([["type": "assistant", "timestamp": "2026-11-14T10:05:00Z", "message": ["stop_reason": "end_turn", "content": []]]]))
        try h.close()
        try r.read()
        #expect(r.items.map(\.kind) == [.prompt, .turnEnd])
    }

    @Test func subAgentsComeFromTheirMetaFiles() throws {
        let dir = try tempDir(), file = dir.appendingPathComponent("cccccccc-2222-3333-4444-555555555555.jsonl")
        try jsonl([["type": "user", "cwd": "/demo/shopfront", "timestamp": "2026-11-14T10:00:00Z", "message": ["content": "Look around"]]]).write(to: file)
        let sub = dir.appendingPathComponent("cccccccc-2222-3333-4444-555555555555/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["agentType": "Explore", "description": "Find payment mocks", "finished": true])
            .write(to: sub.appendingPathComponent("agent-a1.meta.json"))
        let r = SessionReader(url: file, provider: .claude)
        try r.read()
        let s = try #require(r.session())
        #expect(s.subAgents == [SubAgent(id: "agent-a1", type: "Explore", summary: "Find payment mocks", finished: true)])
    }

    // MARK: Codex sessions

    @Test func codexSession() throws {
        let dir = try tempDir(), file = dir.appendingPathComponent("rollout-2026-11-14T10-00-00-0000.jsonl")
        try jsonl([
            ["type": "session_meta", "timestamp": "2026-11-14T10:00:00Z", "payload": ["id": "codex-1", "cwd": "/demo/recipe-box", "git": ["branch": "main"]]],
            ["type": "event_msg", "timestamp": "2026-11-14T10:00:05Z", "payload": ["type": "item_completed", "item": ["type": "UserMessage", "content": [["text": "Add export"]]]]],
            ["type": "event_msg", "timestamp": "2026-11-14T10:00:30Z", "payload": ["type": "item_completed", "item": ["type": "FileChange", "changes": ["/demo/recipe-box/Export.swift": [String: Any]()]]]],
            ["type": "event_msg", "timestamp": "2026-11-14T10:01:00Z", "payload": ["type": "task_complete"]],
        ]).write(to: file)
        let r = SessionReader(url: file, provider: .chatgpt)
        try r.read()
        let s = try #require(r.session())
        #expect(s.id == "codex-1")
        #expect(s.activities.map(\.kind) == [.prompt, .edit, .turnEnd])
        #expect(!r.isSubAgentSession)
    }

    // MARK: commands: only the program leaves the collector

    @Test func commandKinds() {
        #expect(CommandKind.classify("git commit -m 'x'").0 == .commit)
        #expect(CommandKind.classify("cd app && npm test").0 == .test)
        #expect(CommandKind.classify("gh pr create --title x").0 == .push)
        #expect(CommandKind.classify("ssh web01 'systemctl restart web'").0 == .deploy)
        #expect(CommandKind.classify("grep -r test src").0 == .shell)
        #expect(CommandKind.classify("API_TOKEN=secret curl https://example.com").1 == "curl")
    }

    // MARK: world

    @Test func worldGroupsByProviderAndProject() {
        let w = Fixture.world(now: Date())
        #expect(w.building(.claude)?.projects.map(\.name) == ["Lighthouse Site", "Pebble Puzzles", "Shopfront", "Tide Notes", "Chats"])
        #expect(w.building(.chatgpt)?.projects.count == 2)
        // three sessions wait, and the demo factory's two open questions, two to-dos and its held-back release
        #expect(w.waitingSessions.count == 3)
        #expect(w.needsYou.count == 8)
        #expect(w.project(id: "claude:/demo/pebble-puzzles")?.ceoID == "f1")
    }
}
