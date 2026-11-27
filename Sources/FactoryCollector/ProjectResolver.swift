import Foundation
import FactoryCore

/// Finds the project a working folder belongs to (D37). Under ~/Projects the project is the folder right below it
/// (or below ~/Projects/Tuinstra.DEV), so its repos in code/, its docs and its assets are one floor. Elsewhere the git
/// root, with every worktree of a repo counted as that repo; without git the folder itself. The home folder or a scratch
/// folder means the chat is its own project.
/// A folder written the Windows way (`C:\Users\you\Projects\shop`) follows the same rules, with either slash and in
/// any case; its project is spelled as Foundation spells a folder on Windows (`C:/Users/you/Projects/shop`).
public final class ProjectResolver: @unchecked Sendable {
    private let home: String
    private let fm = FileManager.default
    private var cache: [String: ProjectKey] = [:]
    private let lock = NSLock()

    public init(home: String = NSHomeDirectory()) { self.home = home }

    public func resolve(_ cwd: String) -> ProjectKey {
        lock.lock(); defer { lock.unlock() }
        if let k = cache[cwd] { return k }
        let k = compute(cwd)
        cache[cwd] = k
        return k
    }

    private func compute(_ raw: String) -> ProjectKey {
        let cwd = raw.hasPrefix("~") ? home + raw.dropFirst() : raw
        if PathText.isWindows(cwd) { return computeWindows(cwd) }
        let trimmed = cwd.hasSuffix("/") && cwd.count > 1 ? String(cwd.dropLast()) : cwd
        if trimmed == home || trimmed.contains("/scratch-workspaces/") || isTemporary(trimmed) {
            return ProjectKey(root: trimmed, name: "", isChat: true)
        }
        let projects = home + "/Projects/"
        if trimmed.hasPrefix(projects) {
            let parts = trimmed.dropFirst(projects.count).split(separator: "/").map(String.init)
            if let first = parts.first {
                if first.lowercased() == "tuinstra.dev" || first.lowercased() == "tuinstra-dev", parts.count > 1 { return key(projects + first + "/" + parts[1]) }
                return key(projects + first)
            }
        }
        var dir = trimmed
        while !dir.isEmpty, dir != "/", dir != home {
            let git = dir + "/.git"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git, isDirectory: &isDir) {
                let root = isDir.boolValue ? dir : (worktreeMain(gitFile: git, in: dir) ?? dir)
                return key(root)
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return key(trimmed)
    }

    /// A chat in the system's scratch folder (/tmp) is its own project. A home folder that is itself in /tmp is the
    /// exception: what is below it is as real as anywhere (Linux keeps a test's temporary home there).
    private func isTemporary(_ path: String) -> Bool {
        guard path.hasPrefix("/tmp") || path.hasPrefix("/private/tmp") else { return false }
        return !path.hasPrefix(home + "/")
    }

    /// The same rules for a folder written the Windows way.
    private func computeWindows(_ raw: String) -> ProjectKey {
        let cwd = PathText.windows(raw), home = PathText.native(self.home)
        func same(_ a: String, _ b: String) -> Bool { a.lowercased() == b.lowercased() }
        if same(cwd, home) || cwd.lowercased().contains("/scratch-workspaces/") { return ProjectKey(root: cwd, name: "", isChat: true) }
        let projects = home + "/Projects/"
        if cwd.lowercased().hasPrefix(projects.lowercased()) {
            let parts = cwd.dropFirst(projects.count).split(separator: "/").map(String.init)
            if let first = parts.first {
                if first.lowercased() == "tuinstra.dev" || first.lowercased() == "tuinstra-dev", parts.count > 1 { return key(projects + first + "/" + parts[1]) }
                return key(projects + first)
            }
        }
        var dir = cwd
        while !same(dir, home) {
            let git = dir.hasSuffix("/") ? dir + ".git" : dir + "/.git"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git, isDirectory: &isDir) {
                let root = isDir.boolValue ? dir : (worktreeMain(gitFile: git, in: dir) ?? dir)
                return key(root)
            }
            let up = PathText.parent(dir)
            if up == dir { break }   // the drive or the share itself
            dir = up
        }
        return key(cwd)
    }

    /// A worktree's .git is a file: "gitdir: /path/to/repo/.git/worktrees/<name>". The repo is the part before /.git/.
    private func worktreeMain(gitFile: String, in dir: String) -> String? {
        guard let text = try? String(contentsOfFile: gitFile, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if PathText.isWindows(dir) {
            gitdir = PathText.windows(PathText.isWindows(gitdir) ? gitdir : dir + "/" + gitdir)
            guard let r = gitdir.range(of: "/.git/worktrees/") else { return nil }
            return String(gitdir[..<r.lowerBound])
        }
        if !gitdir.hasPrefix("/") { gitdir = ((dir as NSString).appendingPathComponent(gitdir) as NSString).standardizingPath }
        guard let r = gitdir.range(of: "/.git/worktrees/") else { return nil }   // a submodule keeps its own folder
        return String(gitdir[..<r.lowerBound])
    }

    private func key(_ root: String) -> ProjectKey {
        ProjectKey(root: root, name: WorldBuilder.pretty(PathText.name(root)), isChat: false)
    }
}
