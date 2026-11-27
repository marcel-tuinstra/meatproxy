import Foundation
import Testing
@testable import FactoryCollector
import FactoryCore

/// Setting up a factory: Meatproxy offers starter files, shows each one, and writes only what you approve and what is
/// missing. Never an overwrite.
@Suite struct FactoryScaffoldTests {
    func tempProject(_ files: [String: String] = [:]) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scaffold-\(UUID().uuidString)")
        for (rel, text) in files {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(wholeTo: u)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.path
    }

    @Test func aNewProjectGetsTheStarterSetAndAnOptionalAllowlist() throws {
        let root = try tempProject(["Package.swift": "// swift-tools-version: 6.0"])
        #expect(!FactoryScaffold.isSetUp(root))
        let plan = FactoryScaffold.plan(root: root, name: "Pebble")
        #expect(plan.map(\.path) == ["factory/contract.yml", "factory/CHARTER.md", "factory/README.md", "factory/CEO.md",
                                     "factory/autonomy.yml", "factory/mandate.yml", ".claude/settings.json"])
        #expect(plan.allSatisfy { !$0.exists })
        #expect(plan.filter(\.optional).map(\.path) == [".claude/settings.json"])
        // the files say what they are and fit the contract
        let text = Dictionary(uniqueKeysWithValues: plan.map { ($0.path, $0.text) })
        #expect(FactoryText.contract(text["factory/contract.yml"]!) == FactoryContract.current)
        #expect(text["factory/CHARTER.md"]!.contains("Pebble"))
        #expect(text["factory/mandate.yml"]!.contains("level: assistant"))
        // the allowlist knows the project's test command, and never lets the CEO push or merge
        let allow = text[".claude/settings.json"]!
        #expect(allow.contains("Bash(swift test:*)") && allow.contains("\"Bash(git push:*)\"") && allow.contains("deny"))
        #expect((try? JSONSerialization.jsonObject(with: Data(allow.utf8))) != nil)
    }

    @Test func createWritesOnlyWhatIsApprovedAndMissing() throws {
        let root = try tempProject(["factory/CHARTER.md": "# Mine\n"])
        let plan = FactoryScaffold.plan(root: root, name: "Pebble")
        #expect(plan.first { $0.path == "factory/CHARTER.md" }?.exists == true)
        // approve everything except the allowlist; the existing charter is left alone
        let written = try FactoryScaffold.create(plan.filter { !$0.optional }, root: root)
        #expect(!written.contains("factory/CHARTER.md") && written.contains("factory/CEO.md") && !written.contains(".claude/settings.json"))
        #expect(try String(contentsOfFile: root + "/factory/CHARTER.md", encoding: .utf8) == "# Mine\n")
        #expect(!FileManager.default.fileExists(atPath: root + "/.claude/settings.json"))
        // the queue folders are there for the CEO
        for d in ["decisions", "workstreams", "ideas", "briefings"] {
            var dir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: root + "/factory/" + d, isDirectory: &dir) && dir.boolValue)
        }
        #expect(FactoryScaffold.isSetUp(root))
        // a second create writes nothing
        #expect(try FactoryScaffold.create(FactoryScaffold.plan(root: root, name: "Pebble"), root: root) == [".claude/settings.json"])
        #expect(try FactoryScaffold.create(FactoryScaffold.plan(root: root, name: "Pebble"), root: root).isEmpty)
    }

    @Test func theTestCommandFollowsTheProject() throws {
        #expect(FactoryScaffold.testCommands(try tempProject(["package.json": "{}"])) == ["npm test", "npm run build"])
        #expect(FactoryScaffold.testCommands(try tempProject(["Cargo.toml": ""])) == ["cargo test", "cargo build"])
        #expect(FactoryScaffold.testCommands(try tempProject(["go.mod": ""])) == ["go test", "go build"])
        #expect(FactoryScaffold.testCommands(try tempProject(["pyproject.toml": ""])) == ["pytest"])
        #expect(FactoryScaffold.testCommands(try tempProject([:])).isEmpty)
    }
}

/// What the CEO can really do: the project's allowlist, not the mandate, is the lock.
@Suite struct AllowlistTests {
    @Test func theStarterAllowlistTestsAndCommitsButNeverPushesOrMerges() {
        let a = Allowlist(json: FactoryScaffold.allowlist(tests: ["swift test", "swift build"]))
        #expect(a.exists && a.tests && a.commit && !a.push && !a.merge && a.rules > 20)
        #expect(a.line == "Tests yes · commit yes · push no · merge no")
    }

    @Test func broadRulesCountAndADenyWins() {
        let all = Allowlist(json: #"{"permissions":{"allow":["Bash"]}}"#)
        #expect(all.push && all.merge && all.commit)
        let denied = Allowlist(json: #"{"permissions":{"allow":["Bash(git:*)"],"deny":["Bash(git push:*)"]}}"#)
        #expect(denied.commit && !denied.push)
        #expect(!Allowlist(json: nil).exists && Allowlist(json: nil).line == "No allowlist: it can only read and edit files")
        #expect(!Allowlist(json: "not json").exists)
    }
}
