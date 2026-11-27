import Foundation
import FactoryCore

/// The projects you switched on as a Dark Software Factory (D44): their folders, in
/// ~/Library/Application Support/Meatproxy/factories.json. Only these are factories; a `factory/` folder alone
/// does not make one. The app never creates factory files: the factory's CEO writes them.
public struct FactorySettingsStore: Sendable {
    public let url: URL
    public init(url: URL = FactorySettingsStore.defaultURL) { self.url = url }

    public static var defaultURL: URL { ServerSettingsStore.defaultURL.deletingLastPathComponent().appendingPathComponent("factories.json") }

    private struct File: Codable { var factories: [String] }

    /// When the file last changed (nil: there is none), so the app picks up an edit made outside it.
    public var modified: Date? { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }

    public func load() -> [String] {
        guard let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return f.factories
    }

    public func save(_ roots: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(File(factories: roots)).write(wholeTo: url)
    }
}

/// Reads the `factory/` folder of a project you switched on, read-only. The only thing ever written is your answer to
/// a question (`DecisionAnswer`).
public enum FactoryFinder {
    /// Reads one factory: its autonomy, every decision and workstream, and the briefings (only the latest is kept).
    public static func read(root: String) -> Factory {
        let fm = FileManager.default
        var files: [String: String] = [:]
        // (a factory without files yet reads as empty: its CEO has not written anything)
        func load(_ rel: String) { if let t = try? String(contentsOfFile: root + "/" + rel, encoding: .utf8) { files[rel] = t } }
        load("factory/autonomy.yml")
        load("factory/contract.yml")
        load("factory/mandate.yml")
        for folder in ["decisions", "workstreams", "ideas"] {
            for name in (try? fm.contentsOfDirectory(atPath: root + "/factory/" + folder)) ?? [] where name.hasSuffix(".md") { load("factory/\(folder)/\(name)") }
        }
        let briefings = ((try? fm.contentsOfDirectory(atPath: root + "/factory/briefings")) ?? []).filter { $0.hasSuffix(".md") }
        // only the latest one is read; the others are named, so the parser picks the same one
        if let latest = briefings.map({ ($0 as NSString).deletingPathExtension }).max(by: { FactoryText.briefingOrderKey($0) < FactoryText.briefingOrderKey($1) }) {
            load("factory/briefings/\(latest).md")
        }
        return FactoryText.factory(root: root, files: files)
    }
}

/// Writes your yes or no into a decision file: `status`, `answered` (an ISO timestamp) and your note under `## Answer`.
/// Nothing else in the file changes, the write is atomic (a temporary file renamed over it), and a question that is no
/// longer open is never answered again: the CEO may have answered it, withdrawn it or let it expire in the meantime.
public enum DecisionAnswer {
    public enum Failure: Error, Equatable, LocalizedError {
        case unreadable(String)
        case malformed(String)
        case notOpen(String)
        case changed

        public var errorDescription: String? {
            switch self {
            case .unreadable(let why): "The question could not be read: \(why)"
            case .malformed(let why): "The question's file is not in the factory format: \(why)"
            case .notOpen(let status): "This question is no longer open (it is \(status)); nothing was written."
            case .changed: "The question's file changed while answering; nothing was written. Try again."
            }
        }
    }

    /// Answers the decision at `url`. Throws, and writes nothing, when the file is not a decision or not open.
    public static func answer(_ url: URL, yes: Bool, note: String?, at now: Date = Date(), timeZone: TimeZone = .current) throws {
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch { throw Failure.unreadable(error.localizedDescription) }
        let out = try answered(text, yes: yes, note: note, at: now, timeZone: timeZone)
        // the CEO may write the file at the same moment: only replace what we read
        guard (try? String(contentsOf: url, encoding: .utf8)) == text else { throw Failure.changed }
        do { try out.write(wholeTo: url) } catch { throw Failure.unreadable(error.localizedDescription) }
    }

    /// The file's text with the answer in it (the pure part of `answer`, for tests).
    public static func answered(_ text: String, yes: Bool, note: String?, at now: Date, timeZone: TimeZone = .current) throws -> String {
        var lines = text.components(separatedBy: "\n")
        // the front matter: the first non-empty line is ---, up to the next ---
        guard let open = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[open].trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let close = lines[(open + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" })
        else { throw Failure.malformed("no front matter") }
        guard FactoryText.decision(text, file: "") != nil else { throw Failure.malformed("it needs an id, a title and a known status") }
        guard let s = (open + 1..<close).first(where: { lines[$0].hasPrefix("status:") }) else { throw Failure.malformed("no status") }
        let status = FactoryText.value(String(lines[s].dropFirst("status:".count)))
        guard status.lowercased() == "open" else { throw Failure.notOpen(status) }

        let f = ISO8601DateFormatter(); f.timeZone = timeZone; f.formatOptions = [.withInternetDateTime]
        lines[s] = replacingValue(lines[s], key: "status", with: yes ? "yes" : "no")
        if let a = (open + 1..<close).first(where: { lines[$0].hasPrefix("answered:") }) {
            lines[a] = replacingValue(lines[a], key: "answered", with: f.string(from: now))
        } else {
            lines.insert("answered: \(f.string(from: now))", at: s + 1)
        }

        let trimmed = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return lines.joined(separator: "\n") }
        let body = trimmed.components(separatedBy: .newlines)
        // the front matter's closing line has not moved: an inserted answered line comes before it
        let bodyFrom = (lines[(open + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" } ?? close) + 1
        if let h = lines[bodyFrom...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().range(of: #"^#{1,6}\s+answer\s*$"#, options: .regularExpression) != nil }) {
            // the section runs to the next heading (or the end); its old text, if any, gives way to the note
            let next = lines[(h + 1)...].firstIndex(where: { $0.range(of: #"^#{1,6}\s+\S"#, options: .regularExpression) != nil })
            let end = next ?? lines.count
            let tailBlank = next == nil && lines.last == "" ? [""] : []
            let replacement = body + (next != nil ? [""] : tailBlank)
            lines.replaceSubrange((h + 1)..<end, with: replacement)
        } else {
            while lines.last == "" { lines.removeLast() }
            lines += ["", "## Answer"] + body + [""]
        }
        return lines.joined(separator: "\n")
    }

    /// "status: open          # open | yes" → "status: yes           # open | yes": the value changes, the comment stays
    /// where it was.
    static func replacingValue(_ line: String, key: String, with value: String) -> String {
        let rest = line.dropFirst(key.count + 1)
        let lead = rest.prefix { $0 == " " || $0 == "\t" }
        let afterLead = rest.dropFirst(lead.count)
        guard let hash = afterLead.range(of: #"\s+#"#, options: .regularExpression) else { return "\(key):\(lead.isEmpty ? " " : lead)\(value)" }
        let old = afterLead[..<hash.lowerBound], gap = afterLead[hash.lowerBound...].prefix { $0 == " " || $0 == "\t" }
        let comment = afterLead[hash.lowerBound...].dropFirst(gap.count)
        let width = old.count + gap.count
        let pad = max(1, width - value.count)
        return "\(key):\(lead.isEmpty ? " " : lead)\(value)\(String(repeating: " ", count: pad))\(comment)"
    }
}

/// A new file that Meatproxy writes into a factory (an idea, your release): created with O_EXCL, so a file with that name
/// that appeared in the meantime is never replaced. False when the name is taken; throws on any other failure.
public enum NewFile {
    public static func create(_ url: URL, text: String) throws -> Bool {
        #if os(Windows)
        // Windows has no O_EXCL; Foundation's own "never overwrite" asks the system for the same (CREATE_NEW)
        do { try Files.write(Data(text.utf8), to: url, options: .withoutOverwriting); return true }
        catch let e as CocoaError where e.code == .fileWriteFileExists { return false }
        #else
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if fd < 0 {
            if errno == EEXIST { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        defer { close(fd) }
        let data = Data(text.utf8)
        let ok = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) == data.count }
        if !ok { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [NSLocalizedDescriptionKey: "short write"]) }
        return true
        #endif
    }
}

/// Sends the CEO an idea: a new file in `factory/ideas/` (the folder is made when it is missing), the next free id, never
/// overwriting anything. Besides your answers this is the only thing the app writes into a factory (D44).
public enum IdeaInbox {
    public enum Failure: Error, LocalizedError {
        case empty, notWritten(String)
        public var errorDescription: String? {
            switch self {
            case .empty: "Write the idea first."
            case .notWritten(let why): "The idea could not be written: \(why)"
            }
        }
    }

    /// Writes the idea and returns its id ("I-0003").
    @discardableResult
    public static func send(root: String, text: String, at now: Date = Date(), timeZone: TimeZone = .current) throws -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw Failure.empty }
        let fm = FileManager.default, dir = URL(fileURLWithPath: root).appendingPathComponent("factory/ideas")
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { throw Failure.notWritten(error.localizedDescription) }
        let used = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { name -> Int? in
            guard name.hasPrefix("I-") else { return nil }
            return Int(name.dropFirst(2).prefix(while: \.isNumber))
        }
        let firstLine = body.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? body
        let title = firstLine.count > 80 ? String(firstLine.prefix(79)) + "…" : firstLine
        let slug = title.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40)
        let f = ISO8601DateFormatter(); f.timeZone = timeZone; f.formatOptions = [.withInternetDateTime]
        for n in ((used.max() ?? 0) + 1)...((used.max() ?? 0) + 20) {
            let id = String(format: "I-%04d", n)
            let url = dir.appendingPathComponent("\(id)-\(slug.isEmpty ? "idea" : String(slug)).md")
            let file = """
            ---
            id: \(id)
            title: \(title.replacingOccurrences(of: "\n", with: " "))
            status: new          # new | taken | declined
            sent: \(f.string(from: now))
            workstream: null     # the workstream it became
            ---

            \(body)

            ## CEO

            """
            // a file with this name that appeared in the meantime is never overwritten: try the next number
            do { if try NewFile.create(url, text: file) { return id } } catch { throw Failure.notWritten(error.localizedDescription) }
        }
        throw Failure.notWritten("no free id")
    }
}

/// Your release of finished work (contract v5, D81): a new decision in `factory/decisions/` that you started yourself,
/// already answered yes (`kind: ship`, `from: you`). It is your own instruction, so it holds where the mandate keeps
/// shipping off. The next free D-number; an existing file is never overwritten.
public enum ReleaseRequest {
    public enum Failure: Error, LocalizedError {
        case nothing, notWritten(String)
        public var errorDescription: String? {
            switch self {
            case .nothing: "There is nothing to release."
            case .notWritten(let why): "The release could not be written: \(why)"
            }
        }
    }

    /// Writes the request and returns its id ("D-0015").
    @discardableResult
    public static func send(root: String, workstreams: [Workstream], note: String = "", at now: Date = Date(),
                            timeZone: TimeZone = .current) throws -> String {
        guard !workstreams.isEmpty else { throw Failure.nothing }
        let fm = FileManager.default, dir = URL(fileURLWithPath: root).appendingPathComponent("factory/decisions")
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { throw Failure.notWritten(error.localizedDescription) }
        let used = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { name -> Int? in
            guard name.hasPrefix("D-") else { return nil }
            return Int(name.dropFirst(2).prefix(while: \.isNumber))
        }
        let ids = workstreams.map(\.id)
        let f = ISO8601DateFormatter(); f.timeZone = timeZone; f.formatOptions = [.withInternetDateTime]
        let when = f.string(from: now)
        let slug = "release-" + ids.joined(separator: "-").lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
        let list = workstreams.map { "- \($0.id): \($0.title.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n")
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = (used.max() ?? 0) + 1
        for n in start..<(start + 20) {
            let id = String(format: "D-%04d", n)
            let url = dir.appendingPathComponent("\(id)-\(String(slug.prefix(60))).md")
            let file = """
            ---
            id: \(id)
            title: Release \(NeedsYou.list(ids)) to production
            kind: ship
            gate: ship
            status: yes
            from: you             # you started this release in Meatproxy (contract v5)
            workstream: \(ids[0])
            workstreams: [\(ids.joined(separator: ", "))]
            replaces: null
            asked: \(when)
            answered: \(when)
            ---

            ## Why
            You released this work yourself in Meatproxy. It is your own instruction: it holds even where the mandate
            keeps shipping off. Release it the way this factory ships, and log it on each workstream.

            \(list)

            ## Answer
            \(trimmed.isEmpty ? "Release it." : trimmed)

            """
            do { if try NewFile.create(url, text: file) { return id } } catch { throw Failure.notWritten(error.localizedDescription) }
        }
        throw Failure.notWritten("no free id")
    }
}

/// Writes your mandate into a factory (contract v3): factory/mandate.yml, atomically. Besides your answers and your ideas
/// this is the only file Meatproxy writes in a factory, and only in one that declares version 3.
public enum MandateFile {
    public static func write(_ m: FactoryMandate, root: String) throws {
        let u = URL(fileURLWithPath: root).appendingPathComponent("factory/mandate.yml")
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try m.yaml.write(wholeTo: u)
    }
}
