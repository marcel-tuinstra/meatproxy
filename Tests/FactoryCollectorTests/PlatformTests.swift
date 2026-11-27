import Foundation
import Testing
@testable import FactoryCollector
import FactoryCore

/// What differs between a Mac, Linux and Windows. Where a rule is about another system's paths it is plain text, so
/// every rule is checked on every platform.
@Suite struct PlatformTests {
    // MARK: where programs are

    @Test func aProgramIsLookedForInTheUsualPlacesFirstThenOnThePath() {
        let found = Tools.candidates("claude", path: "/usr/bin:/home/you/bin:/usr/local/bin", on: .unix(home: "/home/you"))
        #expect(found == ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/home/you/.local/bin/claude", "/home/you/.claude/local/claude",
                          "/usr/bin/claude", "/home/you/bin/claude"])   // a folder is tried once
        #expect(Tools.candidates("gh", path: nil, on: .unix(home: "/home/you")).count == 4)
    }

    @Test func onWindowsAProgramEndsInExeAndThePathUsesSemicolons() {
        let windows = Tools.System.windows(home: #"C:\Users\you"#, local: #"C:\Users\you\AppData\Local"#)
        let found = Tools.candidates("codex", path: #"C:\Windows\System32;"C:\Program Files\GitHub CLI\";"#, on: windows)
        #expect(found.prefix(4) == [#"C:\Users\you\.local\bin\codex.exe"#, #"C:\Users\you\.local\bin\codex.com"#,
                                    #"C:\Users\you\AppData\Local\Programs\OpenAI\Codex\bin\codex.exe"#,
                                    #"C:\Users\you\AppData\Local\Programs\OpenAI\Codex\bin\codex.com"#])
        #expect(found.contains(#"C:\Program Files\GitHub CLI\codex.exe"#))        // quotes round a folder are dropped
        // a script (.cmd, .bat) needs a shell, and nothing is started through a shell
        #expect(!found.contains { $0.hasSuffix(".cmd") || $0.hasSuffix(".bat") })
        #expect(Tools.candidates("ssh.exe", path: #"C:\Windows\System32\OpenSSH\"#, on: .windows(home: #"C:\Users\you"#, local: nil)).last
                == #"C:\Windows\System32\OpenSSH\ssh.exe"#)
    }

    @Test func aProgramThatIsNotInstalledIsNotFound() {
        #expect(Tools.find("meatproxy-no-such-program-\(UUID().uuidString)") == nil)
        // ssh has a home of its own, so it always has a path to try
        #expect(!Tools.ssh().isEmpty && Tools.ssh("ssh-add").lowercased().contains("ssh-add"))
    }

    // MARK: processes

    @Test func thisProcessLivesAndAnIdNobodyHasDoesNot() {
        #expect(Processes.own > 0)
        #expect(Processes.isAlive(Processes.own))
        #expect(!Processes.isAlive(0x3FFF_FFF0))
    }

    /// Tests run on background threads, which is where Linux blocks signals: started plainly there, this would sleep on.
    @Test(.enabled(if: Stub.available)) func aProcessStartedInTheBackgroundCanBeStopped() throws {
        let p = Process()
        p.executableURL = Stub.sleep(30).executable; p.arguments = Stub.sleep(30).arguments
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        let started = Date()
        try Processes.start(p)
        #expect(Processes.isAlive(p.processIdentifier))
        p.terminate(); p.waitUntilExit()
        #expect(Date().timeIntervalSince(started) < 15)
    }

    // MARK: tokens where there is no Keychain

    @Test func aTokenFromTheEnvironment() {
        #expect(Secrets.fromEnvironment(.sentry, ["MEATPROXY_SENTRY_TOKEN": " abc \n"]) == "abc")
        #expect(Secrets.fromEnvironment(.tracker, ["MEATPROXY_TRACKER_TOKEN": "t"]) == "t")
        #expect(Secrets.fromEnvironment(.sentry, ["MEATPROXY_SENTRY_TOKEN": "  "]) == nil)
        #expect(Secrets.fromEnvironment(.sentry, ["MEATPROXY_TRACKER_TOKEN": "t"]) == nil)
    }

    // MARK: a project on Windows

    @Test func aWindowsFolderResolvesByTheSameRules() {
        let r = ProjectResolver(home: #"C:\Users\you"#)
        // the home folder and a scratch folder are chats
        #expect(r.resolve(#"C:\Users\you"#).isChat)
        #expect(r.resolve(#"c:\users\YOU\"#).isChat)
        #expect(r.resolve(#"C:\Users\you\AppData\scratch-workspaces\a1\x"#).isChat)
        // below ~\Projects the project is the folder right below it, with either slash and in any case
        // (the project is spelled as Foundation spells a folder on Windows, so it is the folder a URL names)
        let shop = r.resolve(#"C:\Users\you\Projects\web-shop\code\api"#)
        #expect(shop == ProjectKey(root: "C:/Users/you/Projects/web-shop", name: "Web Shop", isChat: false))
        #expect(r.resolve("c:/Users/you/projects/web-shop/docs").name == "Web Shop")
        #expect(r.resolve(#"C:\Users\you\Projects\Tuinstra.DEV\meatproxy\code"#).root == "C:/Users/you/Projects/Tuinstra.DEV/meatproxy")
        // anywhere else without git: the folder itself
        #expect(r.resolve(#"D:\work\harbor-api"#) == ProjectKey(root: "D:/work/harbor-api", name: "Harbor API", isChat: false))
        #expect(r.resolve(#"\\nas\team\harbor-api\"#).root == "//nas/team/harbor-api")
        // the home folder may come either way too
        #expect(ProjectResolver(home: "C:/Users/you").resolve(#"C:\Users\you\Projects\web-shop"#) == shop)
    }

    @Test func aSessionsWindowsFolderIsSpelledOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-winpath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("aaaaaaaa-1111-2222-3333-444444444444.jsonl")
        let line: [String: Any] = ["type": "user", "cwd": #"c:\Users\you\Projects\web-shop\code"#, "timestamp": ISO8601DateFormatter().string(from: Date()),
                                   "message": ["content": "Fix the cart"]]
        var data = try JSONSerialization.data(withJSONObject: line); data.append(13); data.append(10)   // Windows ends a line with CR LF
        try data.write(to: file)
        let reader = SessionReader(url: file, provider: .claude)
        try reader.read()
        let s = try #require(reader.session())
        #expect(s.cwd == "C:/Users/you/Projects/web-shop/code" && s.title == "Fix the cart")
        #expect(ProjectResolver(home: #"C:\Users\you"#).resolve(s.cwd).root == "C:/Users/you/Projects/web-shop")
    }

    @Test func aHomeInTheScratchFolderStillHasProjects() {
        // Linux keeps temporary folders in /tmp: a test's home there is a home, and /tmp itself stays scratch
        let r = ProjectResolver(home: "/tmp/home-1")
        #expect(r.resolve("/tmp/home-1/Projects/shop/code").root == "/tmp/home-1/Projects/shop")
        #expect(r.resolve("/tmp/home-1").isChat)
        #expect(r.resolve("/tmp/claude-scratch").isChat && r.resolve("/private/tmp/x").isChat)
        #expect(ProjectResolver(home: "/Users/you").resolve("/tmp/home-1/Projects/shop").isChat)
    }
}

/// Programs that stand in for a CLI in tests: one that sleeps and one that just succeeds, on every platform.
enum Stub {
    static let shell = "/bin/sh"
    /// /bin/sh and friends are there (a Mac, Linux), or Windows's own cmd and PowerShell are
    static var available: Bool { hasShell || FileManager.default.isExecutableFile(atPath: windowsShell) }
    static var hasShell: Bool { FileManager.default.isExecutableFile(atPath: shell) }
    private static var windowsRoot: String { ProcessInfo.processInfo.environment.first { $0.key.lowercased() == "systemroot" }?.value ?? #"C:\Windows"# }
    private static var windowsShell: String { #"\#(windowsRoot)\System32\cmd.exe"# }

    static func sleep(_ seconds: Int) -> HeartbeatRunner.Launch {
        hasShell ? HeartbeatRunner.Launch(executable: URL(fileURLWithPath: shell), arguments: ["-c", "exec sleep \(seconds)"])
            : HeartbeatRunner.Launch(executable: URL(fileURLWithPath: #"\#(windowsRoot)\System32\WindowsPowerShell\v1.0\powershell.exe"#),
                                     arguments: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds \(seconds)"])
    }
    static var succeed: HeartbeatRunner.Launch { exit(0) }
    /// ends at once with this exit code
    static func exit(_ code: Int) -> HeartbeatRunner.Launch {
        hasShell ? HeartbeatRunner.Launch(executable: URL(fileURLWithPath: shell), arguments: ["-c", "exit \(code)"])
            : HeartbeatRunner.Launch(executable: URL(fileURLWithPath: windowsShell), arguments: ["/c", "exit \(code)"])
    }

    /// Runs `body` with the id of a process that lives for as long as `body` takes: what a lock file names when
    /// something else holds it.
    static func whileAnotherProcessLives(_ body: (Int32) throws -> Void) throws {
        let p = Process()
        p.executableURL = sleep(60).executable; p.arguments = sleep(60).arguments
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        try Processes.start(p)
        defer { p.terminate(); p.waitUntilExit() }
        try body(p.processIdentifier)
    }
}
