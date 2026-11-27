import Foundation
import FactoryCore

/// Classifies a shell command by the programs it starts, not by text inside quotes or heredocs.
/// Only the first program and its subcommand leave the collector: full command lines can hold secrets.
enum CommandKind {
    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let push = re(#"^(git push|gh pr (create|merge))\b"#)
    private static let deploy = re(#"^(ssh|scp|rsync|kubectl|helm|fly|vercel|netlify|ansible-playbook|terraform)\b|docker compose up|systemctl (restart|reload)"#)
    private static let test = re(#"\b(test|tests|pytest|vitest|jest|playwright|phpunit|rspec|go test|cargo test|xcodebuild test|swift test|check|lint|tsc)\b"#)
    private static let viewer = re(#"^(grep|rg|cat|echo|ls|find|head|tail|sed|awk|printf)\b"#)
    private static let assignment = re(#"^[A-Za-z_][A-Za-z0-9_]*="#)
    private static let subcommand = re(#"^[a-z][a-z0-9:-]*$"#)
    /// A non-zero exit from these just means "no", not a failure.
    static let quietFail = re(#"^ran (rg|grep|test|diff|cmp|find|ls|\[|git diff|git grep|which|command)\b"#)

    private static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func classify(_ command: String) -> (ActivityKind, String) {
        let body = command.components(separatedBy: "<<").first ?? command
        var segments: [[String]] = []
        for part in body.components(separatedBy: CharacterSet(charactersIn: ";|\n")).flatMap({ $0.components(separatedBy: "&&") }) {
            let words = part.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()")) }
                .filter { !$0.isEmpty && !matches(assignment, $0) }
            if let first = words.first, first != "cd" { segments.append(words) }
        }
        guard let first = segments.first else { return (.shell, "cd") }
        let heads = segments.map { $0.prefix(3).joined(separator: " ") }
        let prog = PathText.name(first[0])
        let sub = first.count > 1 && matches(subcommand, first[1]) ? first[1] : ""
        let label = (prog + " " + sub).trimmingCharacters(in: .whitespaces)
        if heads.contains(where: { matches(push, $0) }) {
            return (.push, heads.contains { $0.hasPrefix("git push") } ? "git push" : "gh pr")
        }
        if heads.contains(where: { $0.hasPrefix("git commit") }) { return (.commit, "git commit") }
        if heads.contains(where: { matches(deploy, $0) }) { return (.deploy, label) }
        if heads.contains(where: { !matches(viewer, $0) && matches(test, $0) }) { return (.test, label) }
        return (.shell, label)
    }

    static func isQuietFail(_ text: String) -> Bool { matches(quietFail, text) }
}
