import Foundation
import FactoryCore

/// The Server room's DevOps agent's workspace (docs/contracts/engine-room.md): a folder that belongs to Meatproxy, with
/// the servers snapshot, the alerts, the agent's decisions and its journal.
public enum EngineRoom {
    public static let contract = "meatproxy-engine-room"
    public static let version = 2
    public static let displayName = "Server room"

    public static var folder: URL { AppSupport.folder.appendingPathComponent("engine-room") }
    public static func isFolder(_ root: String) -> Bool { root.hasSuffix("/engine-room") }
    /// a path in the DevOps agent's workspace: its sessions belong to the Server room, not to a tower floor
    public static func contains(_ path: String) -> Bool { path == folder.path || path.hasPrefix(folder.path + "/") }

    /// Writes what the agent reads before it runs: the contract version, the servers with their last checks, and the
    /// allowlist (the ops tool only).
    public static func prepare(at folder: URL = folder, servers: [ServerConfig], checks: [Server], sites: [String: SiteCheck], opsTool: String) throws {
        let fm = FileManager.default
        for sub in ["alerts", "decisions", "journal", ".claude"] {
            try fm.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try "contract: \(contract)\nversion: \(version)\n".write(wholeTo: folder.appendingPathComponent("contract.yml"))
        try readme.write(wholeTo: folder.appendingPathComponent("README.md"))
        let iso = ISO8601DateFormatter()
        let list: [[String: Any]] = servers.map { c in
            let s = checks.first { $0.id == c.id }
            return [
                "name": c.name, "kind": c.kind.rawValue, "autonomy": c.opsAutonomy.rawValue, "alerts": c.alertsOn,
                "state": s?.state.rawValue ?? "unknown", "detail": s?.detail ?? "", "checked": s?.checkedAt.map(iso.string) ?? "",
                "sites": c.siteURLs.map { u -> [String: Any] in
                    let r = sites[u]
                    return ["url": u, "state": r?.state.rawValue ?? "unknown", "detail": r?.detail ?? "", "checked": r.map { iso.string(from: $0.checkedAt) } ?? ""]
                },
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["servers": list], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(wholeTo: folder.appendingPathComponent("servers.json"))
        let settings: [String: Any] = ["permissions": [
            "allow": ["Read", "Edit", "Write", "Glob", "Grep", "TodoWrite", "Bash(\(opsTool) --ops:*)", "Bash(date)"],
            "deny": ["Bash(ssh:*)", "Bash(scp:*)", "Bash(sudo:*)", "Bash(rm -rf:*)", "Bash(curl:*)"],
        ]]
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(wholeTo: folder.appendingPathComponent(".claude/settings.json"))
    }

    /// The workspace's own copy of the formats (docs/contracts/engine-room.md): what the agent writes, exactly.
    static let readme = """
    # Server room workspace (meatproxy-engine-room v1)

    Meatproxy writes contract.yml, servers.json, this README, .claude/settings.json and alerts/. You write decisions/
    and journal/. Reach servers only with the ops tool (`Meatproxy --ops list`). Formats, exactly:

    ## A question for the user: decisions/D-NNNN-<slug>.md

    The next free number, four digits (D-0001, D-0002 …), a short slug. Meatproxy shows it in Needs you and writes his
    answer into it. Only these front matter fields; required: id, title, status.

    ```markdown
    ---
    id: D-0001
    title: Let the ops tool read Docker on web-01 and web-02?   # one yes/no question
    kind: other            # other | fix | access | spend | todo
    status: open           # open | yes | no | expired | withdrawn
    asked: 2026-11-16T09:37:00+01:00
    answered: null
    ---

    ## Why
    What is wrong, in two or three sentences.

    ## Evidence
    The ops actions you ran and what they said.

    ## On yes
    The exact action(s) you will take.

    ## On no
    What happens instead.

    ## Answer
    ```

    ## An alert: alerts/A-NNNN-<slug>.md (Meatproxy writes it)

    When you have looked at it: set `status: handled` and write what you found and did under `## Agent`.

    `kind: request` (v2) is not a check that failed but work a factory's CEO needs on shared infrastructure, sent by the
    user (subject: the factory; `## Why` and `## How` say what and how). Do what the ops tool and each server allow.
    What is beyond that (code in a repository, a setting you cannot reach) becomes a question or a to-do for the user,
    with the exact steps. Then handle the alert like any other.

    ## The journal: journal/YYYY-MM-DD.md (a second run that day -2)

    `## Briefing` (at most 5 items), `## Needs you` (your open decisions, by id), `## Done`.

    ## What you need from the user (D81)

    Never ask in the journal's prose alone: everything you need from the user is an open decision, so Meatproxy shows it
    with a button. A choice is a yes/no question. Something only they can do (remove a stack, install a sudo rule, sign
    in somewhere) is a to-do: `kind: todo`, an imperative title, `## Why` and `## How` with the exact steps; Meatproxy
    shows Done and Not now. After Done, check it on your next run; after Not now, leave it until something changes.
    """

    /// Files an alert for the agent (a new file, never overwriting one) and returns its id.
    @discardableResult
    public static func file(_ e: AlertEvent, at folder: URL = folder, timeZone: TimeZone = .current) throws -> String {
        let fm = FileManager.default, dir = folder.appendingPathComponent("alerts")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let used = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { n -> Int? in
            n.hasPrefix("A-") ? Int(n.dropFirst(2).prefix(while: \.isNumber)) : nil
        }
        let f = ISO8601DateFormatter(); f.timeZone = timeZone; f.formatOptions = [.withInternetDateTime]
        let slug = e.title.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40)
        var n = (used.max() ?? 0) + 1
        while true {
            let id = String(format: "A-%04d", n)
            let url = dir.appendingPathComponent("\(id)-\(slug).md")
            if fm.fileExists(atPath: url.path) { n += 1; continue }
            let text = """
            ---
            id: \(id)
            title: \(e.title)
            kind: \(e.kind.rawValue)
            subject: \(e.name)
            status: open
            at: \(f.string(from: e.at))
            ---

            \(e.text)

            ## Agent

            """
            guard Files.create(url, contents: Data(text.utf8)) else { throw CocoaError(.fileWriteUnknown) }
            return id
        }
    }

    /// A factory's to-do for the DevOps agent (D86): a request in alerts/ (`kind: request`, the factory as its subject)
    /// with the to-do's why and steps, then the to-do answered with where it went. Returns the request's id.
    @discardableResult
    public static func request(_ d: FactoryDecision, factory name: String, root: String, at folder: URL = folder,
                               now: Date = Date(), timeZone: TimeZone = .current) throws -> String {
        let fm = FileManager.default, dir = folder.appendingPathComponent("alerts")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let used = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { n -> Int? in
            n.hasPrefix("A-") ? Int(n.dropFirst(2).prefix(while: \.isNumber)) : nil
        }
        let f = ISO8601DateFormatter(); f.timeZone = timeZone; f.formatOptions = [.withInternetDateTime]
        let slug = d.title.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40)
        let start = (used.max() ?? 0) + 1
        for n in start..<(start + 20) {
            let id = String(format: "A-%04d", n)
            let text = """
            ---
            id: \(id)
            title: \(d.title.replacingOccurrences(of: "\n", with: " "))
            kind: request
            subject: \(name)
            status: open
            at: \(f.string(from: now))
            from: \(root)/\(d.file)
            ---

            A request from the \(name) factory (\(d.id)), sent by the user from Meatproxy. Do what the ops tool and each
            server allow; anything beyond that becomes a question for the user in decisions/ (or a to-do). Write what you
            did and found under ## Agent.

            ## Why
            \(d.why)

            ## How
            \(d.how)

            ## Agent

            """
            guard try NewFile.create(dir.appendingPathComponent("\(id)-\(slug).md"), text: text) else { continue }
            let decision = URL(fileURLWithPath: root).appendingPathComponent(d.file)
            try DecisionAnswer.answer(decision, yes: true, note: "Sent to the Server room's DevOps agent as \(id). It works on it within what each server allows and writes what it did in its journal.", at: now, timeZone: timeZone)
            return id
        }
        throw CocoaError(.fileWriteUnknown)
    }

    /// The open alerts (title only), for the HUD.
    public static func openAlerts(at folder: URL = folder) -> [(id: String, title: String)] {
        let dir = folder.appendingPathComponent("alerts")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("A-") && $0.hasSuffix(".md") }.sorted()
            .compactMap { name in
                guard let t = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8),
                      let (fm, _) = FactoryText.frontMatter(t), FactoryText.optional(fm["status"]) == "open" else { return nil }
                return (FactoryText.optional(fm["id"]) ?? name, FactoryText.optional(fm["title"]) ?? name)
            }
    }

    /// The newest ops action at or after `since` (D87): which server the DevOps agent works on right now.
    public static func lastAction(since: Date, at folder: URL = folder) -> (server: String, at: Date)? {
        guard let t = try? String(contentsOf: folder.appendingPathComponent("journal/actions.log"), encoding: .utf8) else { return nil }
        let iso = ISO8601DateFormatter()
        for line in t.split(separator: "\n").reversed() {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3, let at = iso.date(from: parts[0]) else { continue }
            return at >= since ? (parts[1], at) : nil
        }
        return nil
    }

    /// The last ops actions on a server, newest first ("22:40 restart nginx → exit 0").
    public static func recentActions(server name: String, limit: Int, at folder: URL = folder) -> [String] {
        guard let t = try? String(contentsOf: folder.appendingPathComponent("journal/actions.log"), encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter(), f = DateFormatter(); f.dateFormat = "dd MMM HH:mm"; f.locale = Locale(identifier: "en_US")
        return t.split(separator: "\n").reversed().compactMap { line -> String? in
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3, parts[1] == name else { return nil }
            return (iso.date(from: parts[0]).map { f.string(from: $0) } ?? parts[0]) + " " + parts[2]
        }.prefix(limit).map { $0 }
    }

    /// The agent's decisions and latest journal, read like a factory, so its questions show and are answered the same way.
    public static func read(at folder: URL = folder) -> Factory {
        let fm = FileManager.default
        var files: [String: String] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent("decisions").path)) ?? [] where name.hasSuffix(".md") {
            if let t = try? String(contentsOf: folder.appendingPathComponent("decisions/\(name)"), encoding: .utf8) { files["factory/decisions/\(name)"] = t }
        }
        let journals = ((try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent("journal").path)) ?? []).filter { $0.hasSuffix(".md") }
            .map { ($0 as NSString).deletingPathExtension }
        if let latest = journals.max(by: { FactoryText.briefingOrderKey($0) < FactoryText.briefingOrderKey($1) }),
           let t = try? String(contentsOf: folder.appendingPathComponent("journal/\(latest).md"), encoding: .utf8) {
            files["factory/briefings/\(latest).md"] = t.replacingOccurrences(of: "## Done", with: "## Delivered")
        }
        var f = FactoryText.factory(root: folder.path, files: files)
        // its files sit in decisions/, not factory/decisions/
        f.decisions = f.decisions.map { var d = $0; d.file = d.file.replacingOccurrences(of: "factory/", with: ""); return d }
        return f
    }
}

/// The only way the DevOps agent reaches a server (docs/contracts/engine-room.md): a fixed set of actions, checked
/// against what that server allows, run with ssh in batch mode, each one logged.
public enum OpsTool {
    public enum Kind: String, Sendable { case read, fix }
    public struct Action: Sendable { public var name: String; public var kind: Kind; public var takesArg: Bool; public var command: @Sendable (String) -> String }

    public static let actions: [Action] = [
        .init(name: "status", kind: .read, takesArg: false) { _ in "uptime; df -h /; free -m" },
        .init(name: "disk", kind: .read, takesArg: false) { _ in "df -h" },
        .init(name: "memory", kind: .read, takesArg: false) { _ in "free -m" },
        .init(name: "services", kind: .read, takesArg: false) { _ in "systemctl --failed --no-legend --no-pager; echo ---; systemctl list-units --type=service --state=running --no-legend --no-pager | head -80" },
        // Docker reads: directly when the account may, else through the narrow sudo rule (docs/contracts/engine-room.md,
        // "On the servers"), which allows exactly these two commands and nothing else of Docker
        .init(name: "docker", kind: .read, takesArg: false) { _ in
            "docker ps -a --format '\(dockerFormat)' 2>/dev/null || sudo -n /usr/bin/docker ps -a --format '\(dockerFormat)'"
        },
        .init(name: "logs", kind: .read, takesArg: true) { a in "journalctl -u \(a) -n 200 --no-pager 2>/dev/null || sudo -n journalctl -u \(a) -n 200 --no-pager" },
        .init(name: "container-logs", kind: .read, takesArg: true) { a in
            "docker logs --tail 200 \(a) 2>&1 || sudo -n /usr/bin/docker logs --tail 200 \(a) 2>&1"
        },
        .init(name: "restart", kind: .fix, takesArg: true) { a in "sudo -n systemctl restart \(a) && systemctl is-active \(a)" },
        .init(name: "restart-container", kind: .fix, takesArg: true) { a in "docker restart \(a)" },
        .init(name: "docker-prune", kind: .fix, takesArg: false) { _ in "docker image prune -af --filter until=168h && docker builder prune -af --filter until=168h" },
        .init(name: "journal-vacuum", kind: .fix, takesArg: false) { _ in "sudo -n journalctl --vacuum-time=7d" },
    ]

    public enum Decision: Equatable, Sendable { case run(String), refused(String) }

    /// what `docker` lists per container (the sudo rule allows `docker ps -a --format` with any format)
    static let dockerFormat = "{{.Names}}\\t{{.Status}}\\t{{.Image}}"

    /// What would run for an action on a server with this autonomy, or why not.
    public static func plan(action name: String, arg: String?, autonomy: OpsAutonomy) -> Decision {
        guard let a = actions.first(where: { $0.name == name }) else { return .refused("unknown action \(name); see --ops list") }
        if a.takesArg {
            guard let arg, arg.range(of: #"^[A-Za-z0-9@._:-]{1,80}$"#, options: .regularExpression) != nil else {
                return .refused("\(name) needs a unit or container name (letters, digits, @ . _ : -)")
            }
        } else if arg != nil { return .refused("\(name) takes no argument") }
        switch (autonomy, a.kind) {
        case (.off, _): return .refused("this server is left alone: nothing runs here")
        case (.observe, .fix): return .refused("this server allows diagnosing only: file a decision with this exact action for the user's yes")
        default: return .run(a.command(arg ?? ""))
        }
    }

    /// Runs an action (the CLI's job): returns the exit code and the output, and logs it.
    public static func run(server: ServerConfig, action: String, arg: String?, log: URL = EngineRoom.folder.appendingPathComponent("journal/actions.log"),
                           ssh: ServerProbe.Runner = ServerProbe.run) -> (Int32, String) {
        let p = plan(action: action, arg: arg, autonomy: server.opsAutonomy)
        let (code, out): (Int32, String)
        switch p {
        case .refused(let why): (code, out) = (2, "refused: \(why)")
        case .run(let cmd):
            let r = ssh(["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", server.host, "--", cmd], 60)
            (code, out) = (r.timedOut ? 124 : r.status, (r.stdout + (r.stderr.isEmpty ? "" : "\n" + r.stderr)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(server.name) \(action)\(arg.map { " " + $0 } ?? "") → \(code == 2 && out.hasPrefix("refused") ? "refused" : "exit \(code)")\n"
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(wholeTo: log) }
        return (code, out)
    }

    /// `--ops list`: the servers, what each allows, and the actions.
    public static func listing(_ servers: [ServerConfig]) -> String {
        var out = "Servers (name, kind, autonomy):\n"
        for s in servers { out += "  \(s.name)  \(s.kind.rawValue)  \(s.opsAutonomy.rawValue)\n" }
        out += "Actions (read: allowed on observe and safeFixes; fix: only on safeFixes):\n"
        for a in actions { out += "  \(a.name)\(a.takesArg ? " <name>" : "")  \(a.kind.rawValue)\n" }
        return out
    }
}
