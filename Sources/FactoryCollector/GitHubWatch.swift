import Foundation
import FactoryCore

/// CI and merged pull requests per project (D67), so the weather means "CI fails" and a drone means "a PR was merged".
/// Every five minutes it asks gh, with your own login, about each project's GitHub repos (the folder itself or its
/// code/<repo> folders). It only reads. A project without a GitHub repo, or without gh, gets no status, and the campus
/// falls back on what the sessions did.
public final class GitHubWatch: @unchecked Sendable {
    public static let interval: TimeInterval = 300
    /// gh in a repo folder with these arguments: its JSON, or nil when gh is missing or fails (tests swap it)
    public typealias GH = @Sendable (_ repo: URL, _ args: [String]) -> Data?

    private let gh: GH
    private let lock = NSLock()
    private var statuses: [String: GitHubStatus] = [:]

    public init(gh: @escaping GH = GitHubWatch.systemGH) { self.gh = gh }

    public func status(root: String) -> GitHubStatus? { lock.lock(); defer { lock.unlock() }; return statuses[root] }

    /// Asks gh about each project folder. Blocking: call it off the main queue.
    public func update(roots: [String], now: Date = Date()) {
        for root in Set(roots) {
            var failing: [String] = [], merged: [Date] = [], read = false
            for repo in HeartbeatCenter.repos(in: root) where Self.onGitHub(repo) {
                if let d = gh(repo, ["run", "list", "--limit", "20", "--json", "databaseId,conclusion,headBranch,status,workflowName"]) {
                    read = true
                    if Self.failing(d) { failing.append(repo.lastPathComponent) }
                }
                if let d = gh(repo, ["pr", "list", "--state", "merged", "--limit", "10", "--json", "number,mergedAt"]) {
                    read = true
                    merged += Self.merged(d)
                }
            }
            lock.lock()
            statuses[root] = read ? GitHubStatus(failing: failing, merged: merged, checkedAt: now) : nil
            lock.unlock()
        }
    }

    /// Whether the newest finished run of any workflow on main, master or develop failed (gh lists newest first).
    static func failing(_ data: Data) -> Bool {
        guard let runs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return false }
        var seen: Set<String> = []
        for r in runs where ["main", "master", "develop"].contains(r["headBranch"] as? String ?? "") && (r["status"] as? String) == "completed" {
            let wf = r["workflowName"] as? String ?? ""
            guard !seen.contains(wf) else { continue }
            seen.insert(wf)
            if (r["conclusion"] as? String) == "failure" { return true }
        }
        return false
    }

    /// When the pull requests were merged.
    static func merged(_ data: Data) -> [Date] {
        guard let prs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        return prs.compactMap { ($0["mergedAt"] as? String).flatMap(iso.date(from:)) }
    }

    /// A repo whose remote is on GitHub (read from .git/config; nothing is run for the others).
    static func onGitHub(_ repo: URL) -> Bool {
        let cfg = repo.appendingPathComponent(".git/config")
        return ((try? String(contentsOf: cfg, encoding: .utf8)) ?? "").contains("github.com")
    }

    /// gh with your own login (20 s at most).
    public static let systemGH: GH = { repo, args in
        guard let gh = Tools.find("gh") else { return nil }
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = args
        p.currentDirectoryURL = repo
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try Processes.start(p) } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(20)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { p.terminate(); return nil }
        return p.terminationStatus == 0 ? data : nil
    }
}
