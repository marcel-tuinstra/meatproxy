import Foundation

/// Folders as text, read the way they were written. A session file names its folders as its own system writes them:
/// `/Users/you/Projects/shop` on a Mac or Linux, `C:\Users\you\Projects\shop` on Windows. The Mac and Linux way is
/// left to Foundation, as before; the Windows way is read here, the same on every platform.
public enum PathText {
    /// Written the Windows way: on a drive (`C:\shop`, `c:/shop`, `C:`) or on a share (`\\server\share`, `//server/share`).
    public static func isWindows(_ path: String) -> Bool {
        if path.hasPrefix(#"\\"#) || path.hasPrefix("//") { return true }
        let c = Array(path.unicodeScalars.prefix(3))
        guard c.count >= 2, c[0].isASCII, c[0].properties.isAlphabetic, c[1] == ":" else { return false }
        return c.count == 2 || c[2] == #"\"# || c[2] == "/"
    }

    /// The last folder or file of a path ("shop").
    public static func name(_ path: String) -> String {
        guard isWindows(path) else { return (path as NSString).lastPathComponent }
        let p = read(path)
        return p.below.last ?? p.top
    }

    /// The folder a path is in. A drive or a share is its own parent.
    public static func parent(_ path: String) -> String {
        guard isWindows(path) else { return (path as NSString).deletingLastPathComponent }
        var p = read(path)
        if !p.below.isEmpty { p.below.removeLast() }
        return p.text
    }

    /// One spelling for a Windows folder, the one Foundation gives a path there: forward slashes, the drive in
    /// capitals, no `.` or `..`, no slash at the end (a drive keeps its own: `C:/`). So a folder from a session file
    /// (`c:\Users\you\shop`) and the same folder from a URL (`C:/Users/you/shop`) are one folder.
    public static func windows(_ path: String) -> String { read(path).text }

    /// A folder in the one spelling the rest of Meatproxy compares and opens: a Windows folder as `windows` spells
    /// it, any other as it is.
    public static func native(_ path: String) -> String { isWindows(path) ? windows(path) : path }

    /// A Windows path taken apart: what it starts with and never loses (`C:` or `//server/share`), and the folders below.
    private struct Parts {
        var top: String, below: [String], share: Bool
        var text: String {
            if share { return below.isEmpty ? top : top + "/" + below.joined(separator: "/") }
            return top + "/" + below.joined(separator: "/")
        }
    }

    private static func read(_ path: String) -> Parts {
        let flat = path.replacingOccurrences(of: #"\"#, with: "/")
        let share = flat.hasPrefix("//")
        let words = flat.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let fixed = share ? min(2, words.count) : min(1, words.count)
        var below: [String] = []
        for w in words.dropFirst(fixed) {
            if w == "." { continue }
            if w == ".." { if !below.isEmpty { below.removeLast() }; continue }
            below.append(w)
        }
        let top = share ? "//" + words.prefix(fixed).joined(separator: "/") : (words.first ?? "").uppercased()
        return Parts(top: top, below: below, share: share)
    }
}
