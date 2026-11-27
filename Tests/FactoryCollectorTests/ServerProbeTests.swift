import Foundation
import Testing
import FactoryCore
@testable import FactoryCollector

/// The Server room's live source: servers checked over SSH, never with a password, read-only.
struct ServerProbeTests {
    private let web = ServerConfig(id: "w", name: "web-01", host: "deploy@web-01.example.com")

    private func fake(_ status: Int32, _ stdout: String = "", _ stderr: String = "", timedOut: Bool = false) -> ServerProbe.Runner {
        { _, _ in ServerProbe.Output(status: status, stdout: stdout, stderr: stderr, timedOut: timedOut) }
    }

    @Test func neverAsksForAPasswordAndKeepsHostKeyChecks() {
        let a = ServerProbe.arguments(for: web)
        #expect(a.contains("BatchMode=yes"))
        #expect(!a.joined(separator: " ").contains("StrictHostKeyChecking"))
        // the host comes after "--", so it can never be read as an option
        #expect(a.firstIndex(of: "--")! < a.firstIndex(of: "deploy@web-01.example.com")!)
    }

    @Test func refusesHostsThatLookLikeOptions() {
        #expect(!ServerConfig.validHost("-oProxyCommand=evil"))
        #expect(!ServerConfig.validHost("web 01"))
        #expect(!ServerConfig.validHost(""))
        #expect(ServerConfig.validHost("deploy@web-01.example.com"))
        #expect(ServerConfig.validHost("web01"))           // a Host alias from ~/.ssh/config
        var bad = web; bad.host = "-oProxyCommand=evil"
        #expect(ServerProbe.check(bad, run: fake(0, "cores 2")).state == .down)
    }

    @Test func readsAHealthyServer() {
        let r = ServerProbe.check(web, run: fake(0, "cores 2\nload 0.69\ndisk 67%\nmem 4000000000 2200000000\n"))
        #expect(r.state == .ok)
        #expect(r.detail == "load 0.69 · disk 67% · memory 45%")
    }

    @Test func warnsOnAFullDiskHighLoadOrLittleMemory() {
        #expect(ServerProbe.health("cores 4\nload 0.2\ndisk 93%").state == .warn)
        #expect(ServerProbe.health("cores 4\nload 0.2\ndisk 93%").detail == "disk 93% full")
        #expect(ServerProbe.health("cores 2\nload 3.4\ndisk 40%").state == .warn)
        #expect(ServerProbe.health("cores 16\nload 5.5\ndisk 61%").state == .ok)       // 0.34 per core
        #expect(ServerProbe.health("mem 1000 50").state == .warn)
        #expect(ServerProbe.health("cores \nload \ndisk ").detail == "reachable")    // a box without these tools
    }

    @Test func saysWhyItCouldNotGetIn() {
        let pw = ServerProbe.check(web, run: fake(255, "", "deploy@web-01.example.com: Permission denied (publickey,password)."))
        #expect(pw.state == .down && pw.needsKey && !pw.reached)
        // what ssh really prints when no key gets in (captured from a live run), exit 255
        let real = ServerProbe.check(web, run: fake(255, "", "no such identity: /x: No such file or directory\ngit@example.com: Permission denied (publickey).\n"))
        #expect(real.needsKey && !real.reached)
        #expect(ServerProbe.failure("Host key verification failed.").detail.contains("host key"))
        #expect(ServerProbe.failure("ssh: Could not resolve hostname nope: nodename nor servname provided").detail == "host name not found")
        #expect(ServerProbe.failure("ssh: connect to host x port 22: Operation timed out").detail == "no connection: timed out")
        #expect(ServerProbe.check(web, run: fake(0, timedOut: true)).detail.hasPrefix("no answer"))
    }

    @Test func runsACheckOfYourOwn() {
        var backup = web; backup.kind = .backup; backup.check = "test -n \"$(find /backups -mmin -1500)\""
        #expect(ServerProbe.arguments(for: backup).last == backup.check)
        #expect(ServerProbe.check(backup, run: fake(0, "last backup 3 h ago\n")) == .init(state: .ok, detail: "last backup 3 h ago"))
        #expect(ServerProbe.check(backup, run: fake(1)).state == .warn)
        #expect(ServerProbe.check(backup, run: fake(2)).state == .down)
        #expect(ServerProbe.check(backup, run: fake(2)).reached)      // it got in; the check itself failed
    }

    @Test func storesHostNamesOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ServerSettingsStore(url: dir.appendingPathComponent("servers.json"))
        #expect(store.load().isEmpty)
        try store.save([web])
        #expect(store.load() == [web])
        #expect(store.modified != nil)      // the app watches this to pick up edits made outside it
    }

    @Test func showsOnlyCheckedServers() async {
        let m = ServerMonitor(configs: [web], run: fake(0, "cores 1\nload 0.1\ndisk 10%"))
        #expect(m.servers.isEmpty)       // never a guessed state
        await withCheckedContinuation { c in m.checkAll { c.resume() } }
        #expect(m.servers.map(\.state) == [.ok])
        m.update([])
        #expect(m.servers.isEmpty)
    }
}

struct UserEnvironmentTests {
    /// The app's ssh gets the agent that holds your keys, whatever agent it was started with.
    @Test func sshGetsTheAgentWithKeys() {
        #expect(UserEnvironment.withSSHAgent(["HOME": "/x"], agent: { "/tmp/agent.sock" })["SSH_AUTH_SOCK"] == "/tmp/agent.sock")
        #expect(UserEnvironment.withSSHAgent(["SSH_AUTH_SOCK": "/own.sock"], agent: { "/keys.sock" })["SSH_AUTH_SOCK"] == "/keys.sock")
        #expect(UserEnvironment.withSSHAgent(["SSH_AUTH_SOCK": "/own.sock"], agent: { nil })["SSH_AUTH_SOCK"] == "/own.sock")
    }

    @Test func aSocketThatIsNotAnAgentHasNoKeys() {
        #expect(!UserEnvironment.hasKeys("/nonexistent/agent.sock"))
        #expect(UserEnvironment.agentSockets(URL(fileURLWithPath: "/nonexistent")).isEmpty)
    }
}

/// Alerts without crying wolf (D49).
struct AlertTrackerTests {
    @Test func badTwiceThenAlertWorseAgainThenRecovered() {
        let t = AlertTracker()
        #expect(t.observe("web", name: "web-01", state: .ok, detail: nil) == nil)
        #expect(t.observe("web", name: "web-01", state: .warn, detail: "disk 91% full") == nil)     // once: maybe a blip
        #expect(t.observe("web", name: "web-01", state: .warn, detail: "disk 91% full")?.kind == .warn)
        #expect(t.observe("web", name: "web-01", state: .warn, detail: "disk 92% full") == nil)     // told already
        #expect(t.observe("web", name: "web-01", state: .down, detail: "no answer")?.kind == .down) // worse: news
        #expect(t.observe("web", name: "web-01", state: .down, detail: "no answer") == nil)
        let back = t.observe("web", name: "web-01", state: .ok, detail: "load 0.3")
        #expect(back?.kind == .recovered && back?.title == "web-01 is fine again")
        #expect(t.observe("web", name: "web-01", state: .ok, detail: nil) == nil)
    }

    @Test func aBlipIsNoAlertAndSitesSayWhy() {
        let t = AlertTracker()
        #expect(t.observe("s", name: "s", state: .down, detail: nil) == nil)
        #expect(t.observe("s", name: "s", state: .ok, detail: nil) == nil)          // never alerted: no recovery either
        let now = Date()
        #expect(SiteCheck(url: "https://x", status: 200, certDaysLeft: 60, checkedAt: now).state == .ok)
        #expect(SiteCheck(url: "https://x", status: 200, certDaysLeft: 5, checkedAt: now).state == .warn)
        #expect(SiteCheck(url: "https://x", status: 502, certDaysLeft: 60, checkedAt: now).state == .down)
        #expect(SiteCheck(url: "https://x", error: "timed out", checkedAt: now).state == .down)
        #expect(SiteCheck(url: "https://x", status: 200, certDaysLeft: 5, checkedAt: now).detail == "HTTP 200 · certificate expires in 5 days")
    }

    @Test func olderServerSettingsKeepTheirDefaults() throws {
        let c = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"id":"a","name":"web-01","host":"deploy@web-01.example.com","kind":"server"}"#.utf8))
        #expect(c.alertsOn && c.opsAutonomy == .observe && c.siteURLs.isEmpty)
    }
}

/// The Server room's DevOps agent (docs/contracts/engine-room.md): the ops tool decides, not the agent.
struct EngineRoomTests {
    private func temp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("sf-ops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func theOpsToolFollowsEachServersAutonomy() {
        #expect(OpsTool.plan(action: "disk", arg: nil, autonomy: .observe) == .run("df -h"))
        if case .refused(let why) = OpsTool.plan(action: "restart", arg: "nginx", autonomy: .observe) { #expect(why.contains("file a decision")) } else { Issue.record("observe restarted") }
        #expect(OpsTool.plan(action: "restart", arg: "nginx", autonomy: .safeFixes) == .run("sudo -n systemctl restart nginx && systemctl is-active nginx"))
        if case .refused = OpsTool.plan(action: "status", arg: nil, autonomy: .off) {} else { Issue.record("off read") }
        // nothing but a plain name gets onto the command line
        for bad in ["nginx; rm -rf /", "$(id)", "a b", "", String(repeating: "x", count: 81)] {
            if case .refused = OpsTool.plan(action: "logs", arg: bad, autonomy: .safeFixes) {} else { Issue.record("let through \(bad)") }
        }
        if case .refused = OpsTool.plan(action: "reboot", arg: nil, autonomy: .safeFixes) {} else { Issue.record("unknown action ran") }
        // Docker reads go directly, or through exactly the commands the narrow sudo rule allows (never the docker group)
        if case .run(let cmd) = OpsTool.plan(action: "docker", arg: nil, autonomy: .observe) {
            #expect(cmd.contains("|| sudo -n /usr/bin/docker ps -a --format '{{.Names}}\\t{{.Status}}\\t{{.Image}}'"))
        } else { Issue.record("docker refused") }
        if case .run(let cmd) = OpsTool.plan(action: "container-logs", arg: "web", autonomy: .observe) {
            #expect(cmd.hasSuffix("|| sudo -n /usr/bin/docker logs --tail 200 web 2>&1"))
        } else { Issue.record("container-logs refused") }
        if case .refused = OpsTool.plan(action: "disk", arg: "x", autonomy: .safeFixes) {} else { Issue.record("stray argument") }
    }

    @Test func everyActionIsLoggedAndRefusalsNeverReachSSH() throws {
        let dir = try temp(), log = dir.appendingPathComponent("journal/actions.log")
        nonisolated(unsafe) var calls: [[String]] = []
        let ssh: ServerProbe.Runner = { args, _ in calls.append(args); return .init(status: 0, stdout: "Filesystem 40%", stderr: "") }
        let s = ServerConfig(name: "web-01", host: "deploy@web-01.example.com", autonomy: .observe)
        let (ok, out) = OpsTool.run(server: s, action: "disk", arg: nil, log: log, ssh: ssh)
        #expect(ok == 0 && out == "Filesystem 40%")
        #expect(calls.first == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "deploy@web-01.example.com", "--", "df -h"])
        let (no, why) = OpsTool.run(server: s, action: "docker-prune", arg: nil, log: log, ssh: ssh)
        #expect(no == 2 && why.hasPrefix("refused") && calls.count == 1)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2 && lines[0].hasSuffix("web-01 disk → exit 0") && lines[1].hasSuffix("web-01 docker-prune → refused"))
    }

    @Test func theWorkspaceHoldsServersAlertsAndQuestions() throws {
        let dir = try temp()
        let s = ServerConfig(id: "a", name: "api-01", host: "deploy@api-01.example.com", autonomy: .safeFixes, urls: ["https://api.example.com/health"])
        try EngineRoom.prepare(at: dir, servers: [s], checks: [Server(id: "a", name: "api-01", kind: .server, state: .warn, detail: "disk 91% full")],
                               sites: [:], opsTool: "/Applications/Meatproxy.app/Contents/MacOS/Meatproxy")
        let settings = try String(contentsOf: dir.appendingPathComponent(".claude/settings.json"), encoding: .utf8)
        #expect(settings.contains("Bash(/Applications/Meatproxy.app/Contents/MacOS/Meatproxy --ops:*)") && settings.contains("Bash(ssh:*)"))
        let servers = try String(contentsOf: dir.appendingPathComponent("servers.json"), encoding: .utf8)
        #expect(servers.contains("\"autonomy\" : \"safeFixes\"") && servers.contains("disk 91% full"))
        #expect(try String(contentsOf: dir.appendingPathComponent("contract.yml"), encoding: .utf8).contains("meatproxy-engine-room"))
        let e = AlertEvent(key: "a", name: "api-01", kind: .warn, text: "disk 91% full", at: Date())
        #expect(try EngineRoom.file(e, at: dir) == "A-0001" && (try EngineRoom.file(e, at: dir)) == "A-0002")
        #expect(EngineRoom.openAlerts(at: dir).map(\.id) == ["A-0001", "A-0002"])
        try "---\nid: D-0001\ntitle: Prune old images on api-01?\nkind: other\nstatus: open\n---\n\n## Why\nDisk.\n"
            .write(wholeTo: dir.appendingPathComponent("decisions/D-0001-prune.md"))
        let f = EngineRoom.read(at: dir)
        #expect(f.openDecisions.map(\.file) == ["decisions/D-0001-prune.md"])
    }

    @Test func theDevOpsAgentIsOneMoreHeartbeat() throws {
        let center = HeartbeatCenter(runner: HeartbeatRunner(folder: try temp(), resolve: { _ in Stub.succeed },
                                                             directory: { _ in FileManager.default.temporaryDirectory }))
        var settings = ProjectSettings()
        center.wake(EngineRoom.folder.path, .alert(["A-0001"]))
        #expect(center.tick(settings).isEmpty)                    // off: nothing
        settings.devops.enabled = true
        #expect(center.tick(settings) == [EngineRoom.folder.path])
        center.runner.wait(EngineRoom.folder.path)
        #expect(HeartbeatRunner.prompt(root: EngineRoom.folder.path, name: "x", reason: .alert(["A-0001"])).contains("--ops list"))
    }
}

struct ServerSizeTests {
    /// The gauges say how much, not only how full: disk in GB from df, memory from free.
    @Test func theCheckReadsSizes() {
        let r = ServerProbe.health("cores 2\nload 0.3\ndisk 50%\ndiskkb 39845888 19922944\nmem 4000000000 2290000000")
        let m = r.metrics
        #expect(m?.disk == 50 && m?.diskTotalBytes == 39845888 * 1024 && m?.diskUsedBytes == 19922944 * 1024)
        #expect(ServerMetrics.size(m?.diskUsedBytes, of: m?.diskTotalBytes) == "19 of 38 GB")
        #expect(ServerMetrics.size(m?.memoryUsedBytes, of: m?.memoryTotalBytes) == "1.6 of 3.7 GB")
        #expect(ServerMetrics.size(400_000_000, of: 1_073_741_824) == "381 MB of 1.0 GB")
        #expect(ServerMetrics.size(nil, of: 1) == nil)
    }
}

struct ProjectLogoTests {
    @Test func aProjectsLogoIsFoundInItsOwnFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sf-logo-\(UUID().uuidString)")
        let web = root.appendingPathComponent("code/app/web/icons")
        try fm.createDirectory(at: web, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 200).write(to: web.appendingPathComponent("Icon-192.png"))
        #expect(ProjectLogo.search(root.path)?.hasSuffix("code/app/web/icons/Icon-192.png") == true)
        // a logo at the top wins over a repo's web icon
        try Data(repeating: 1, count: 200).write(to: root.appendingPathComponent("logo.png"))
        #expect(ProjectLogo.search(root.path)?.hasSuffix("/logo.png") == true)
        // an app icon set further down
        let other = fm.temporaryDirectory.appendingPathComponent("sf-logo-\(UUID().uuidString)")
        let set = other.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
        try fm.createDirectory(at: set, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: set.appendingPathComponent("small.png"))
        try Data(repeating: 1, count: 900).write(to: set.appendingPathComponent("large.png"))
        #expect(ProjectLogo.search(other.path)?.hasSuffix("large.png") == true)
        #expect(ProjectLogo.search(fm.temporaryDirectory.appendingPathComponent("sf-none-\(UUID().uuidString)").path) == nil)
    }
}

extension EngineRoomTests {
    @Test func theWorkspaceCarriesItsFormats() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-ops-\(UUID().uuidString)")
        try EngineRoom.prepare(at: dir, servers: [], checks: [], sites: [:], opsTool: "/x/Meatproxy")
        let readme = try String(contentsOf: dir.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme.contains("decisions/D-NNNN-<slug>.md") && readme.contains("status: open"))
        #expect(HeartbeatRunner.opsPrompt(root: dir.path, reason: .runNow).contains("Read README.md first"))
        // the example in the README is a decision the app reads
        let example = readme.components(separatedBy: "```markdown\n")[1].components(separatedBy: "```")[0]
        #expect(FactoryText.decision(example, file: "decisions/D-0001-x.md")?.status == .open)
    }
}

/// Adding servers in one go: the Host aliases in ~/.ssh/config, without wildcards or negations.
@Suite struct SSHHostsTests {
    @Test func aliasesFromAnSSHConfig() {
        let text = """
        # my servers
        Host web-01 web-02
          HostName 203.0.113.10
          User deploy
        Host *.example.com
          User me
        Host  api-01   # the api
        Host !bastion db-0?
        Match host foo
        host lowercase-alias
        Include ~/.ssh/other
        Host *
          ServerAliveInterval 30
        """
        #expect(SSHHosts.aliases(text) == ["web-01", "web-02", "api-01", "lowercase-alias"])
        #expect(SSHHosts.aliases("") == [])
    }
}
