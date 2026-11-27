import Foundation

/// Where a working folder belongs: its git root, the folder itself, or nowhere (then the chat is its own project).
public struct ProjectKey: Hashable, Sendable {
    public var root: String
    public var name: String
    public var isChat: Bool
    public init(root: String, name: String, isChat: Bool) { self.root = root; self.name = name; self.isChat = isChat }
}

public enum WorldBuilder {
    /// One CEO per project (D47): the heartbeat's runs are the same CEO waking again, so a floor shows only the latest run;
    /// the earlier ones are in the heartbeat card and its logs. Sessions come newest first.
    static func oneCEO(_ sessions: [Session]) -> [Session] {
        var seen = false
        return sessions.filter { s in
            guard s.heartbeatRun == true else { return true }
            defer { seen = true }
            return !seen
        }
    }

    /// Groups sessions into buildings (provider) and floors (project). Floors keep a fixed order (D15):
    /// projects by name, chats on top.
    /// Loose chats (D46) share one Chats floor per provider; with `showChats` off they are left out.
    public static func build(_ sessions: [Session], now: Date = Date(), showChats: Bool = true, resolve: (String) -> ProjectKey) -> World {
        var floors: [String: Project] = [:]
        for s in sessions {
            let key = resolve(s.projectRoot ?? s.cwd)
            if key.isChat && !showChats { continue }
            let id = key.isChat ? "\(s.provider.rawValue):chats" : "\(s.provider.rawValue):\(key.root)"
            let name = key.isChat ? "Chats" : key.name
            floors[id, default: Project(id: id, provider: s.provider, root: key.root, name: name, isChat: key.isChat, sessions: [])].sessions.append(s)
        }
        let buildings = Provider.allCases.map { p in
            let projects = floors.values.filter { $0.provider == p }
                .map { var pr = $0; pr.sessions = oneCEO(pr.sessions.sorted { $0.lastAt > $1.lastAt }); return pr }
                .sorted { ($0.isChat ? 1 : 0, $0.name.lowercased()) < ($1.isChat ? 1 : 0, $1.name.lowercased()) }
            return ProviderBuilding(provider: p, projects: projects)
        }
        return World(now: now, buildings: buildings)
    }

    /// Takes the floors you hid off the campus (a factory stays: it is never hidden).
    public static func hide(_ roots: [String], in world: inout World) {
        guard !roots.isEmpty else { return }
        let hidden = Set(roots)
        for b in world.buildings.indices {
            world.buildings[b].projects.removeAll { !$0.isChat && $0.factory == nil && hidden.contains($0.root) }
        }
    }

    /// Puts every factory you switched on on its project's floor. It stays on the campus with or without a session in the last
    /// hours: its questions wait for you whether its CEO runs now or ran this morning. A project at two providers gets it on
    /// the floor with the latest session (so its questions count once); a factory without sessions lives in `provider`.
    public static func attach(_ factories: [Factory], to world: inout World, provider: Provider = .claude) {
        for f in factories {
            let floors = world.projects.filter { !$0.isChat && $0.root == f.root }
            if let home = floors.max(by: { ($0.sessions.first?.lastAt ?? .distantPast) < ($1.sessions.first?.lastAt ?? .distantPast) }),
               let b = world.buildings.firstIndex(where: { $0.provider == home.provider }),
               let k = world.buildings[b].projects.firstIndex(where: { $0.id == home.id }) {
                world.buildings[b].projects[k].factory = f
            } else if let b = world.buildings.firstIndex(where: { $0.provider == provider }) {
                let p = Project(id: "\(provider.rawValue):\(f.root)", provider: provider, root: f.root,
                                name: pretty(PathText.name(f.root)), isChat: false, sessions: [], factory: f)
                world.buildings[b].projects.append(p)
                world.buildings[b].projects.sort { ($0.isChat ? 1 : 0, $0.name.lowercased()) < ($1.isChat ? 1 : 0, $1.name.lowercased()) }
            }
        }
    }

    /// Keeps the projects you pinned on the campus (D46): a pinned project without a recent session gets an empty floor in
    /// `provider`'s building. A project already on a floor is left as it is.
    public static func pin(_ roots: [String], to world: inout World, provider: Provider = .claude) {
        for root in roots where !world.projects.contains(where: { !$0.isChat && $0.root == root }) {
            guard let b = world.buildings.firstIndex(where: { $0.provider == provider }) else { continue }
            world.buildings[b].projects.append(Project(id: "\(provider.rawValue):\(root)", provider: provider, root: root,
                                                       name: pretty(PathText.name(root)), isChat: false, sessions: []))
            world.buildings[b].projects.sort { ($0.isChat ? 1 : 0, $0.name.lowercased()) < ($1.isChat ? 1 : 0, $1.name.lowercased()) }
        }
    }

    /// "pebble-puzzles" → "Pebble Puzzles", like the web prototype.
    public static func pretty(_ folder: String) -> String {
        folder.split(whereSeparator: { "-_ ".contains($0) }).map { w in
            let s = String(w)
            return ["ui", "api", "ios", "qa", "dev"].contains(s.lowercased()) ? s.uppercased() : s.prefix(1).uppercased() + s.dropFirst()
        }.joined(separator: " ")
    }
}

/// Fictional data for screenshots and demos, so no real titles or prompts end up in something shared.
public enum Fixture {
    public static func world(now: Date = Date()) -> World {
        func ago(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }
        /// A session whose last actions are `acts` (oldest first, a minute apart), the last one `last` minutes ago.
        func s(_ id: String, _ p: Provider, _ cwd: String, _ title: String, _ last: Double, open: Bool, acts: [ActivityKind] = [.edit],
               failed: Bool = false, moons: [SubAgent] = [], branch: String? = nil) -> Session {
            var list = [Activity(at: ago(last + Double(acts.count) + 1), kind: .prompt, text: "asked for a change")]
            for (k, kind) in acts.enumerated() {
                let label: String
                switch kind {
                case .test: label = "ran npm test"
                case .read: label = "read CheckoutView.swift"
                case .shell: label = "ran npm run build"
                case .plan: label = "planned the change"
                case .push: label = "pushed the branch"
                case .commit: label = "committed the fix"
                case .browse: label = "opened the docs"
                default: label = "edited CheckoutView.swift"
                }
                list.append(Activity(at: ago(last + Double(acts.count - 1 - k)), kind: kind, text: label, failed: failed && k == acts.count - 1))
            }
            return Session(id: id, provider: p, cwd: cwd, title: title, branch: branch, model: p == .claude ? "claude-opus" : "gpt-codex",
                           startedAt: ago(last + 40), lastAt: ago(last), turnOpen: open, activities: list, subAgents: moons)
        }
        let sessions = [
            s("a1", .claude, "/demo/shopfront", "Fix flaky checkout test", 2, open: false, acts: [.delegate, .read, .test],
              moons: [SubAgent(id: "m1", type: "Explore", summary: "Find payment mocks", finished: true),
                      SubAgent(id: "m2", type: "code-review", summary: "Review the fix", finished: false)], branch: "fix/checkout-flake"),
            s("a2", .claude, "/demo/shopfront", "Dark mode for settings", 0.5, open: true, acts: [.read, .edit, .edit, .edit], branch: "feat/settings-dark"),
            s("a3", .claude, "/demo/shopfront", "Update shipping copy", 90, open: false, acts: [.edit, .commit]),
            s("a7", .claude, "/demo/shopfront", "Retry failed payments", 0.4, open: true, acts: [.edit, .test], failed: true),
            s("a8", .claude, "/demo/shopfront", "Speed up the product grid", 0.2, open: true, acts: [.edit, .shell, .shell]),
            s("a9", .claude, "/demo/shopfront", "Gift cards at checkout", 0.6, open: true, acts: [.edit, .test, .plan, .plan]),
            s("a10", .claude, "/demo/shopfront", "Why do orders double", 0.3, open: true, acts: [.read, .browse, .read]),
            s("a11", .claude, "/demo/shopfront", "Release 2.4", 120, open: false, acts: [.test, .commit, .push]),
            s("a4", .claude, "/demo/tide-notes", "Sync notes offline", 1, open: true),
            s("a5", .claude, "/demo/lighthouse-site", "New pricing page", 120, open: false),
            s("a6", .claude, "~", "Pick a font pairing", 6, open: false),
            // the demo factory's morning CEO run, and the developer it handed the timer bug to
            s("f1", .claude, factoryRoot, "Pebble factory: CEO run", 150, open: false, acts: [.read, .delegate, .delegate, .plan, .edit],
              moons: [SubAgent(id: "fm1", type: "product", summary: "Propose the next workstream", finished: true),
                      SubAgent(id: "fm2", type: "tester", summary: "Test W-002 against its criteria", finished: true)]),
            s("f2", .claude, factoryRoot, "W-003 timer keeps time after resume", 0.5, open: true, acts: [.read, .test, .edit, .edit],
              branch: "bug/W-003-timer-resume"),
            s("b1", .chatgpt, "/demo/recipe-box", "Add grocery list export", 14, open: false),
            s("b2", .chatgpt, "/demo/recipe-box", "Fix image upload", 0.3, open: true,
              moons: [SubAgent(id: "m3", type: "reviewer", summary: "Check the upload limits", finished: false)]),
            s("b3", .chatgpt, "/demo/harbor-api", "Rate-limit the public API", 0.4, open: true, acts: [.edit, .test], failed: true),
        ]
        let said: [String: String] = [
            "a1": "The flaky test waited on a fixed 2-second timer; it now waits for the payment mock to answer. 40 runs in a row pass.\n\nShall I open the PR against develop, or do you want to look at the diff first?",
            "a6": "Two pairings fit the brand: Inter with JetBrains Mono, or Inter with IBM Plex Mono for a softer code look.\n\nWhich one do you want?",
            "b1": "Export works for CSV and plain text. PDF would need a new dependency (about 400 KB).\n\nShould I add PDF export too, or ship CSV and text first?",
        ]
        // where each runs (D83): Rue's chat is in the Claude app, the rest in a terminal
        let withSaid = sessions.map { s -> Session in
            var s = s; s.lastSaid = said[s.id]; s.entrypoint = s.id == "a1" ? "claude-desktop" : "cli"; return s
        }
        var world = WorldBuilder.build(withSaid, now: now) { cwd in
            cwd == "~" ? ProjectKey(root: "~", name: "", isChat: true)
                : ProjectKey(root: cwd, name: WorldBuilder.pretty(PathText.name(cwd)), isChat: false)
        }
        WorldBuilder.attach([factory(now: now)], to: &world)
        // GitHub (D67): the made-up Harbor API's CI on main is red, so it rains over the ChatGPT tower
        for b in world.buildings.indices { for p in world.buildings[b].projects.indices where world.buildings[b].projects[p].root == "/demo/harbor-api" {
            world.buildings[b].projects[p].github = GitHubStatus(failing: ["harbor-api"], merged: [ago(300)], checkedAt: now)
        } }
        world.servers = servers
        // the status pages (D69), made up: OpenAI degraded, the others fine
        world.services = [
            ServiceStatus(id: "claude", name: "Claude", page: "https://status.claude.com", state: .ok, detail: "All Systems Operational", checkedAt: ago(2), runtime: "claude"),
            ServiceStatus(id: "openai", name: "OpenAI", page: "https://status.openai.com", state: .degraded, detail: "Partially Degraded Service", checkedAt: ago(2), runtime: "codex"),
            ServiceStatus(id: "github", name: "GitHub", page: "https://www.githubstatus.com", state: .ok, detail: "All Systems Operational", checkedAt: ago(2)),
        ]
        return world
    }

    /// A small, made-up Server room: four servers, a deploy and a backup, one of them warning and one down.
    public static let servers: [Server] = [
        Server(id: "web-01", name: "web-01", kind: .server, state: .ok, detail: "load 0.4 · disk 61% · memory 42%", metrics: ServerMetrics(load: 0.4, cores: 4, disk: 61, memory: 42, diskUsedBytes: 52398601011, diskTotalBytes: 85899345920, memoryUsedBytes: 3607772528, memoryTotalBytes: 8589934592)),
        Server(id: "api-01", name: "api-01", kind: .server, state: .warn, detail: "disk 91% full", metrics: ServerMetrics(load: 0.62, cores: 2, disk: 91, memory: 58, diskUsedBytes: 39084202393, diskTotalBytes: 42949672960, memoryUsedBytes: 2491081031, memoryTotalBytes: 4294967296)),
        Server(id: "db-01", name: "db-01", kind: .server, state: .ok, detail: "load 1.12 · disk 54% · memory 71%", metrics: ServerMetrics(load: 1.12, cores: 4, disk: 54, memory: 71, diskUsedBytes: 92771293593, diskTotalBytes: 171798691840, memoryUsedBytes: 12197707120, memoryTotalBytes: 17179869184)),
        Server(id: "cache-01", name: "cache-01", kind: .server, state: .ok, detail: "load 0.08 · disk 22% · memory 63%", metrics: ServerMetrics(load: 0.08, cores: 2, disk: 22, memory: 63, diskUsedBytes: 9448928051, diskTotalBytes: 42949672960, memoryUsedBytes: 1352914698, memoryTotalBytes: 2147483648)),
        Server(id: "shopfront", name: "shopfront", kind: .deploy, state: .ok, detail: "load 0.21 · disk 38% · memory 40%", metrics: ServerMetrics(load: 0.21, cores: 2, disk: 38, memory: 40, diskUsedBytes: 10200547328, diskTotalBytes: 26843545600, memoryUsedBytes: 858993459, memoryTotalBytes: 2147483648)),
        Server(id: "nightly", name: "nightly", kind: .backup, state: .down, detail: "no connection: timed out"),
    ]
}
