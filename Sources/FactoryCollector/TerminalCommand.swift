import Foundation
import FactoryCore

/// What a tab in Meatproxy's terminal runs (D57): taking over a session where its agent left it, ssh to a server, or
/// following a run's log. Built only from checked parts (a session id, a host, an existing log file), never from free
/// text, and run directly, never through a shell.
public struct TerminalCommand: Equatable, Sendable {
    public var title: String
    public var executable: String
    public var args: [String]
    public var cwd: String?
    public init(title: String, executable: String, args: [String], cwd: String?) {
        self.title = title; self.executable = executable; self.args = args; self.cwd = cwd
    }

    /// `claude --resume <id>` (or `codex resume <id>`) in the folder the session started in: its agent's conversation,
    /// now in your hands. nil when the id is not a plain id or the CLI is missing.
    public static func resume(_ s: Session, cli: (String) -> String? = HeartbeatRunner.cli) -> TerminalCommand? {
        guard s.id.range(of: #"^[A-Za-z0-9._-]{4,80}$"#, options: .regularExpression) != nil else { return nil }
        var isDir: ObjCBool = false
        let cwd = FileManager.default.fileExists(atPath: s.cwd, isDirectory: &isDir) && isDir.boolValue ? s.cwd : NSHomeDirectory()
        switch s.provider {
        case .claude:
            guard let exe = cli("claude") else { return nil }
            return TerminalCommand(title: s.title, executable: exe, args: ["--resume", s.id], cwd: cwd)
        case .chatgpt:
            guard let exe = cli("codex") else { return nil }
            return TerminalCommand(title: s.title, executable: exe, args: ["resume", s.id], cwd: cwd)
        }
    }

    /// ssh to a server with your own keys and config. nil when the host is not a plain name.
    public static func ssh(_ host: String, name: String) -> TerminalCommand? {
        guard host.range(of: #"^[A-Za-z0-9@._:-]+$"#, options: .regularExpression) != nil, !host.hasPrefix("-") else { return nil }
        return TerminalCommand(title: "ssh \(name)", executable: Tools.ssh(), args: [host], cwd: NSHomeDirectory())
    }

    /// Follows a log as it grows (a CEO's or the DevOps agent's run). nil when the file is not there.
    public static func follow(_ path: String, title: String) -> TerminalCommand? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let tail = "/usr/bin/tail"
        return TerminalCommand(title: title, executable: Tools.isProgram(tail) ? tail : Tools.find("tail") ?? tail, args: ["-n", "400", "-f", path], cwd: nil)
    }

    /// The environment a tab runs in: yours, with the ssh-agent that holds your keys, the usual tool paths, a colour
    /// terminal, and nothing of a Claude Code session the app may have been started from.
    public static func environment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var env = UserEnvironment.withSSHAgent(base)
        for k in env.keys where k.hasPrefix("CLAUDE") || k == "ANTHROPIC_BASE_URL" { env[k] = nil }
        Tools.addSearchPath(to: &env)
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }
}
