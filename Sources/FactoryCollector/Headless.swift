import Foundation
import FactoryCore

/// Meatproxy without a window: what the collector sees, the costs, the ops tool and the heartbeat, as text on the
/// command line. The Mac app runs these as `Meatproxy --dump` and so on; `meatproxy-core` is the same modes on macOS,
/// Linux and Windows, where there is no campus yet.
public enum Headless {
    public static let usage = """
        meatproxy-core: Meatproxy without a window.

          --dump               what the collector sees: every tower, floor and chat, and what waits for you
          --watch [seconds]    the same, again whenever it changes (looks every 5 seconds)
          --costs              each floor's sessions at API prices
          --ops list           the DevOps agent's ops tool: the servers and what each allows
          --ops <server> <action> [name]
          --heartbeat          start every factory whose beat is due, wait for them, exit
          --fixture            with --dump or --watch: made-up demo data instead of your own sessions
        """

    /// Runs the mode the arguments ask for and returns its exit code. nil when they ask for none of these: the app
    /// then opens its window.
    public static func run(_ arguments: [String], out: (String) -> Void = { print($0) }) -> Int32? {
        let fixture = arguments.contains("--fixture") || arguments.contains("--first-run")
        // `--dump` prints what the collector sees, like `python3 live.py`.
        if arguments.contains("--dump") {
            let world = fixture ? Fixture.world() : Collector().world(settings: ProjectSettingsStore().load())
            dump(world).forEach(out)
            return 0
        }
        // `--watch`: the dump again whenever something changed, until you stop it.
        if let k = arguments.firstIndex(of: "--watch") {
            let seconds = arguments.count > k + 1 ? Double(arguments[k + 1]).map { max(1, $0) } ?? 5 : 5
            let collector = Collector(), stamp = DateFormatter(); stamp.dateFormat = "HH:mm:ss"
            var last: [String] = []
            while true {
                let world = fixture ? Fixture.world() : collector.world(settings: ProjectSettingsStore().load())
                let lines = dump(world)
                // the clock in a chat's line ticks on its own: only what the campus shows counts as a change
                if lines != last {
                    out("── \(stamp.string(from: Date())) ──"); lines.forEach(out); last = lines
                    // into a pipe (another program reads along) output waits in a buffer: send each change at once
                    fflush(stdout)
                }
                Thread.sleep(forTimeInterval: seconds)
            }
        }
        // `--costs`: what every floor's sessions would have cost at API prices (D61); reads and updates the ledger.
        if arguments.contains("--costs") {
            let collector = Collector()
            let started = Date()
            collector.costs.update()
            let world = collector.world(settings: ProjectSettingsStore().load())
            out("Read in \(String(format: "%.1f", Date().timeIntervalSince(started))) s; prices of \(ApiPrices.asOf)")
            for b in world.buildings { for p in b.projects.sorted(by: { ($0.cost?.month ?? 0) > ($1.cost?.month ?? 0) }) {
                guard let c = p.cost else { continue }
                out("  \(pad(b.provider.displayName, 8)) \(pad(p.name, 28)) today \(ProjectCost.format(c.today))  7 d \(ProjectCost.format(c.week))  30 d \(ProjectCost.format(c.month))\(c.unpricedTokens > 0 ? "  (\(c.unpricedTokens) unpriced tokens)" : "")")
            } }
            return 0
        }
        // `--ops <server> <action> [name]` (docs/contracts/engine-room.md): the DevOps agent's only way onto a server,
        // checked against what that server allows in Meatproxy's own settings.
        if let k = arguments.firstIndex(of: "--ops") {
            let args = Array(arguments.dropFirst(k + 1))
            let servers = ServerSettingsStore().load()
            if args.first == "list" || args.isEmpty {
                let text = OpsTool.listing(servers)
                out(text.hasSuffix("\n") ? String(text.dropLast()) : text); return 0
            }
            guard args.count >= 2, let server = servers.first(where: { $0.name == args[0] }) else {
                out("refused: unknown server \(args.first ?? ""); see --ops list"); return 2
            }
            let (code, text) = OpsTool.run(server: server, action: args[1], arg: args.count > 2 ? args[2] : nil)
            out(text)
            return code
        }
        // `--heartbeat` (the launch agent, D47): start every factory whose beat is due, wait for them, exit.
        if arguments.contains("--heartbeat") {
            let settings = ProjectSettingsStore().load()
            let center = HeartbeatCenter()
            let started = center.tick(settings)
            for root in started { center.runner.wait(root) }
            out("Heartbeat: \(started.count) run(s)")
            return 0
        }
        return nil
    }

    /// The world as lines of text: each tower with its floors and chats, each factory, and the Needs you list in the
    /// order the app shows it.
    public static func dump(_ world: World) -> [String] {
        var lines: [String] = []
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        for b in world.buildings {
            lines.append("\(b.provider.displayName): \(b.projects.count) floor(s)")
            for p in b.projects {
                lines.append("  \(p.isChat ? "chat" : "proj") \(p.name)  [\(p.sessions.count) session(s)]")
                for s in p.sessions {
                    lines.append("     \(f.string(from: s.lastAt)) \(pad(s.state(now: world.now).rawValue, 8)) \(s.activities.count) items, \(s.subAgents.count) sub-agents  \(s.title.prefix(48))")
                }
            }
        }
        for p in world.projects { if let f = p.factory {
            lines.append("Factory \(p.name): \(f.autonomy?.level.rawValue ?? "no autonomy.yml")\(f.paused ? " PAUSED" : ""), \(f.activeWorkstreams.count) workstream(s), \(f.openDecisions.count) open question(s), briefing \(f.briefing?.name ?? "none")\(f.problems.isEmpty ? "" : ", unreadable: \(f.problems.joined(separator: ", "))")")
        } }
        let needs = world.needsYou
        lines.append("Needs you: \(needs.count)")
        for n in needs { lines.append("  \(pad(n.group.label, 11)) \(n.project.name): \(n.title)") }
        return lines
    }

    /// A word in a column of `width`: padded with spaces, cut when longer.
    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? String(text.prefix(width)) : text + String(repeating: " ", count: width - text.count)
    }
}
