import Foundation
import FactoryCore

/// The projects you keep on the campus (D46) and which of them are Dark Software Factories (D44), with each factory's
/// heartbeat (D47). Floors still come automatically from your sessions (the developer who works in a CLI or IDE needs
/// no setup); a pinned project stays on the campus without a session; a factory is a pinned project whose CEO the app
/// wakes. Loose chats share one Chats floor, which can be switched off.
public struct ProjectSettings: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var root: String
        /// on the campus even without a recent session
        public var pinned: Bool
        /// a Dark Software Factory: its factory/ files show, and its CEO has a heartbeat
        public var factory: Bool
        public var heartbeat: Heartbeat
        public var id: String { root }
        public init(root: String, pinned: Bool = true, factory: Bool = false, heartbeat: Heartbeat = Heartbeat()) {
            self.root = root; self.pinned = pinned; self.factory = factory; self.heartbeat = heartbeat
        }
    }
    public var projects: [Entry] = []
    /// loose chats (the home folder, scratch folders) on one shared floor per provider
    public var showChats = true
    /// a launch agent wakes factories while the app is closed (off: heartbeats beat only while the app runs)
    public var heartbeatWhenClosed = false
    /// the kill switch (D48): no heartbeat starts anything, and running CEOs are stopped
    public var pauseAll = false
    /// the Server room's DevOps agent and its alerts
    public var devops = DevOpsSettings()
    /// project folders you hid from the campus (a factory is never hidden)
    public var hidden: [String] = []
    /// factories whose CEO may not run Dark: Assistant and Hybrid only
    public var darkOff: [String] = []
    public func darkAllowed(_ root: String) -> Bool { !darkOff.contains(root) }
    /// your Tracker's MCP address (https); empty: Tracker is off
    public var trackerURL = ""
    /// the campus default team (D79): every factory floor follows it until it has its own
    public var defaultTeam = AgentTeam.campusStart
    /// profiles you made yourself, offered on every floor
    public var customProfiles: [CustomProfile] = []

    public init(projects: [Entry] = [], showChats: Bool = true, heartbeatWhenClosed: Bool = false) {
        self.projects = projects; self.showChats = showChats; self.heartbeatWhenClosed = heartbeatWhenClosed
    }

    public var factoryRoots: [String] { projects.filter(\.factory).map(\.root) }
    /// every project kept on the campus: pinned ones and factories
    public var pinnedRoots: [String] { projects.filter { $0.pinned || $0.factory }.map(\.root) }
    public func entry(_ root: String) -> Entry? { projects.first { $0.root == root } }

    /// Changes one project's entry (adding it when new); an entry neither pinned nor a factory is dropped.
    public mutating func update(_ root: String, _ change: (inout Entry) -> Void) {
        var e = entry(root) ?? Entry(root: root, pinned: false)
        change(&e)
        projects.removeAll { $0.root == root }
        if e.pinned || e.factory { projects.append(e) }
    }

    // tolerant decoding: a field added later has its default
    enum CodingKeys: String, CodingKey { case projects, showChats, heartbeatWhenClosed, pauseAll, devops, hidden, darkOff, trackerURL, defaultTeam, customProfiles }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([Entry].self, forKey: .projects) ?? []
        showChats = try c.decodeIfPresent(Bool.self, forKey: .showChats) ?? true
        heartbeatWhenClosed = try c.decodeIfPresent(Bool.self, forKey: .heartbeatWhenClosed) ?? false
        pauseAll = try c.decodeIfPresent(Bool.self, forKey: .pauseAll) ?? false
        devops = try c.decodeIfPresent(DevOpsSettings.self, forKey: .devops) ?? DevOpsSettings()
        hidden = try c.decodeIfPresent([String].self, forKey: .hidden) ?? []
        darkOff = try c.decodeIfPresent([String].self, forKey: .darkOff) ?? []
        trackerURL = try c.decodeIfPresent(String.self, forKey: .trackerURL) ?? ""
        defaultTeam = try c.decodeIfPresent(AgentTeam.self, forKey: .defaultTeam) ?? .campusStart
        customProfiles = try c.decodeIfPresent([CustomProfile].self, forKey: .customProfiles) ?? []
    }
}

/// ~/Library/Application Support/Meatproxy/projects.json. The first time, the list of switched-on factories from
/// factories.json (D44) is taken over: each becomes a pinned factory with the default heartbeat.
public struct ProjectSettingsStore: Sendable {
    public let url: URL
    let legacy: URL
    public init(folder: URL = AppSupport.folder) {
        url = folder.appendingPathComponent("projects.json")
        legacy = folder.appendingPathComponent("factories.json")
    }

    public var modified: Date? { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }

    public func load() -> ProjectSettings {
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(ProjectSettings.self, from: data) { return s }
        let roots = FactorySettingsStore(url: legacy).load()
        return ProjectSettings(projects: roots.map { ProjectSettings.Entry(root: $0, pinned: true, factory: true) })
    }

    public func save(_ s: ProjectSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(s).write(wholeTo: url)
    }
}

/// The Server room's DevOps agent (it watches your servers and sites, and may work semi-autonomously per server) and the
/// alerts the app sends you. Off until you switch it on; alerts are on.
public struct DevOpsSettings: Codable, Equatable, Sendable {
    public var enabled = false
    /// its own rhythm (a daily look round) and runtime; your answers wake it like a factory's CEO
    /// Claude Code by default: its allowlist holds it to the ops tool; Codex has no allowlist (only its sandbox)
    public var heartbeat = Heartbeat(days: .everyDay, times: ["08:00"], runtime: .claude, wakeOnAnswer: true, wakeOnCI: false)
    /// a new alert wakes it
    public var wakeOnAlert = true
    /// alerts as notifications on this Mac
    public var notify = true
    public init() {}
    enum CodingKeys: String, CodingKey { case enabled, heartbeat, wakeOnAlert, notify }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), x = DevOpsSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? x.enabled
        heartbeat = try c.decodeIfPresent(Heartbeat.self, forKey: .heartbeat) ?? x.heartbeat
        wakeOnAlert = try c.decodeIfPresent(Bool.self, forKey: .wakeOnAlert) ?? x.wakeOnAlert
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? x.notify
    }
}
