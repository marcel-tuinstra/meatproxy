import Foundation
import Testing
@testable import FactoryCollector
import FactoryCore

/// D67: CI and merged pull requests from gh, with a fake gh and made-up repos.
@Suite struct GitHubWatchTests {
    func repo(_ remote: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "[remote \"origin\"]\n\turl = \(remote)\n".write(wholeTo: root.appendingPathComponent(".git/config"))
        return root
    }
    let runs = """
    [{"databaseId":9,"conclusion":"","headBranch":"main","status":"in_progress","workflowName":"CI"},
     {"databaseId":8,"conclusion":"failure","headBranch":"main","status":"completed","workflowName":"CI"},
     {"databaseId":7,"conclusion":"success","headBranch":"main","status":"completed","workflowName":"CI"},
     {"databaseId":6,"conclusion":"failure","headBranch":"feature/x","status":"completed","workflowName":"CI"}]
    """
    let prs = #"[{"number":8,"mergedAt":"2026-11-16T19:40:00Z"},{"number":7,"mergedAt":"2026-11-16T19:20:00Z"}]"#

    @Test func theNewestFinishedRunOnMainDecides() {
        #expect(GitHubWatch.failing(Data(runs.utf8)))
        // a later green run on main clears it; a red run on a branch never counts
        let green = #"[{"conclusion":"success","headBranch":"main","status":"completed","workflowName":"CI"},{"conclusion":"failure","headBranch":"main","status":"completed","workflowName":"CI"}]"#
        #expect(!GitHubWatch.failing(Data(green.utf8)))
        let branch = #"[{"conclusion":"failure","headBranch":"feature/x","status":"completed","workflowName":"CI"}]"#
        #expect(!GitHubWatch.failing(Data(branch.utf8)))
        // another workflow failing on main does count
        let other = #"[{"conclusion":"success","headBranch":"main","status":"completed","workflowName":"CI"},{"conclusion":"failure","headBranch":"main","status":"completed","workflowName":"Deploy"}]"#
        #expect(GitHubWatch.failing(Data(other.utf8)))
    }

    @Test func aProjectGetsItsStatusOnlyFromGitHubRepos() throws {
        let gh = try repo("git@github.com:demo/pebble.git"), other = try repo("https://gitlab.example.com/demo/x.git")
        let asked = Box()
        let w = GitHubWatch { url, args in
            asked.add(url.lastPathComponent + " " + args[0])
            return Data((args[0] == "run" ? self.runs : self.prs).utf8)
        }
        w.update(roots: [gh.path, other.path], now: Date(timeIntervalSince1970: 0))
        let s = try #require(w.status(root: gh.path))
        #expect(s.ciFailing && s.failing == [gh.lastPathComponent])
        #expect(s.merged.count == 2 && s.merged == s.merged.sorted())
        #expect(w.status(root: other.path) == nil)
        #expect(asked.items.allSatisfy { $0.hasPrefix(gh.lastPathComponent) })
    }

    @Test func noGhNoStatus() throws {
        let gh = try repo("https://github.com/demo/pebble")
        let w = GitHubWatch { _, _ in nil }
        w.update(roots: [gh.path])
        #expect(w.status(root: gh.path) == nil)
    }
}

final class Box: @unchecked Sendable {
    private let lock = NSLock(); private var list: [String] = []
    func add(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
    var items: [String] { lock.lock(); defer { lock.unlock() }; return list }
}
