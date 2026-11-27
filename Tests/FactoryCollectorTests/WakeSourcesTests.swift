import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import FactoryCollector
import FactoryCore

/// D61: Sentry and Tracker wake a factory's CEO. The network is answered here; nothing leaves the machine.
@Suite struct WakeSourcesTests {
    /// A fake network: answers by the request's host and, for MCP, the JSON-RPC method; records what was asked.
    final class Fake: @unchecked Sendable {
        var sentryIssues: [[String: Any]] = []
        var stories: [String: [[String: Any]]] = ["rejected": [], "unstarted": []]
        var asked: [URLRequest] = []
        var eventStream = false

        var transport: HTTPTransport {
            { [self] r in
                asked.append(r)
                if r.url?.host?.hasSuffix("sentry.io") == true {
                    return (try! JSONSerialization.data(withJSONObject: sentryIssues), 200, [:])
                }
                let body = (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
                switch body["method"] as? String {
                case "initialize":
                    return (try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2025-06-18"]]), 200, ["mcp-session-id": "s-1"])
                case "notifications/initialized":
                    return (Data(), 202, [:])
                case "tools/call":
                    let state = ((body["params"] as? [String: Any])?["arguments"] as? [String: Any])?["state"] as? String ?? ""
                    let payload = String(decoding: try! JSONSerialization.data(withJSONObject: ["items": stories[state] ?? [], "nextCursor": NSNull()]), as: UTF8.self)
                    let reply: [String: Any] = ["jsonrpc": "2.0", "id": 2, "result": ["content": [["type": "text", "text": payload]], "isError": false]]
                    let json = try! JSONSerialization.data(withJSONObject: reply)
                    if eventStream { return (Data("event: message\ndata: \(String(decoding: json, as: UTF8.self))\n\n".utf8), 200, ["content-type": "text/event-stream"]) }
                    return (json, 200, [:])
                default: return nil
                }
            }
        }
    }

    private let sources = FactorySources(sentryOrg: "demo-org", sentryProject: "pebble-app", tracker: "pebble")
    static let tracker = URL(string: "https://tracker.example.com/mcp")!

    private func factories(bugs: Bool = true, hb: Heartbeat = Heartbeat()) -> [(root: String, sources: FactorySources, heartbeat: Heartbeat, bugsAllowed: Bool)] {
        [("/demo/pebble-puzzles", sources, hb, bugs)]
    }

    @Test func contractNamesItsSources() {
        let text = """
        contract: meatproxy-factory
        version: 4
        sentry: demo-org/pebble-app   # org/project
        sentry-host: de.sentry.io
        tracker: pebble
        """
        #expect(FactoryText.contract(text) == 4)
        let s = FactoryText.sources(text)
        #expect(s.sentryOrg == "demo-org" && s.sentryProject == "pebble-app" && s.sentryHost == "de.sentry.io" && s.tracker == "pebble")
        // a host that is not Sentry's, or a slug with a slash or a space, is ignored
        let bad = FactoryText.sources("sentry: a/b/c\nsentry-host: evil.example.com\ntracker: my project")
        #expect(!bad.hasSentry && bad.sentryHost == "sentry.io" && bad.tracker == nil)
    }

    @Test func sentryWakesForNewAndReturningErrorsAfterAFirstLook() {
        let fake = Fake(), w = WakeSources(transport: fake.transport)
        fake.sentryIssues = [["id": "1", "shortId": "PEB-1", "title": "TypeError in board", "substatus": "ongoing"]]
        // the first look only notes
        #expect(w.check(factories(), tokens: ("sntry", nil)).isEmpty)
        #expect(fake.asked.first?.value(forHTTPHeaderField: "Authorization") == "Bearer sntry")
        #expect(fake.asked.first?.url?.absoluteString.hasPrefix("https://sentry.io/api/0/projects/demo-org/pebble-app/issues/?") == true)
        // a new error, and the old one comes back
        fake.sentryIssues = [["id": "1", "shortId": "PEB-1", "title": "TypeError in board", "substatus": "regressed"],
                             ["id": "2", "shortId": "PEB-2", "title": "Crash on resume", "substatus": "new"]]
        let wakes = w.check(factories(), tokens: ("sntry", nil))
        #expect(wakes.count == 1)
        if case .sentry(let ids)? = wakes.first?.1 { #expect(ids == ["PEB-1: TypeError in board", "PEB-2: Crash on resume"]) }
        else { Issue.record("no Sentry wake") }
        // nothing new: no wake
        #expect(w.check(factories(), tokens: ("sntry", nil)).isEmpty)
    }

    @Test func noSentryWakeWhenBugsAreOffOrTheSwitchIsOffOrNoToken() {
        let fake = Fake(), w = WakeSources(transport: fake.transport)
        var off = Heartbeat(); off.wakeOnSentry = false
        _ = w.check(factories(bugs: false), tokens: ("sntry", nil))
        _ = w.check(factories(hb: off), tokens: ("sntry", nil))
        _ = w.check(factories(), tokens: (nil, nil))
        #expect(fake.asked.isEmpty)
    }

    @Test func trackerWakesForStoriesThatChangeOverMCP() {
        for stream in [false, true] {
            let fake = Fake(), w = WakeSources(transport: fake.transport)
            fake.eventStream = stream
            fake.stories["unstarted"] = [["key": "PEB-7", "title": "Daily puzzle archive", "state": "unstarted"]]
            #expect(w.check(factories(), tokens: (nil, "trk"), trackerURL: Self.tracker).isEmpty)
            // the MCP handshake, then the call, with the session and the token
            let calls = fake.asked.filter { $0.url?.host == "tracker.example.com" }
            #expect(calls.count == 6 && calls.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer trk" })
            #expect(calls[1].value(forHTTPHeaderField: "Mcp-Session-Id") == "s-1")
            // PEB-7 is rejected now, PEB-8 is new and ready
            fake.stories["unstarted"] = [["key": "PEB-8", "title": "Hint button", "state": "unstarted"]]
            fake.stories["rejected"] = [["key": "PEB-7", "title": "Daily puzzle archive", "state": "rejected"]]
            let wakes = w.check(factories(), tokens: (nil, "trk"), trackerURL: Self.tracker)
            if case .tracker(let ids)? = wakes.first?.1 { #expect(ids == ["PEB-7 rejected: Daily puzzle archive", "PEB-8 ready: Hint button"]) }
            else { Issue.record("no Tracker wake (event stream: \(stream))") }
        }
    }

    /// Tracker is anyone's: without an address in Settings it is off, whatever the token.
    @Test func trackerNeedsAnAddress() {
        let fake = Fake(), w = WakeSources(transport: fake.transport)
        _ = w.check(factories(), tokens: (nil, "trk"))
        #expect(fake.asked.isEmpty)
        #expect(WakeSources.trackerURL("https://tracker.example.com/mcp") == Self.tracker)
        #expect(WakeSources.trackerURL("  https://tracker.example.com/mcp \n") == Self.tracker)
        #expect(WakeSources.trackerURL("http://tracker.example.com/mcp") == nil && WakeSources.trackerURL("") == nil
                && WakeSources.trackerURL("tracker.example.com") == nil)
    }

    /// A source that stops working says so, and since when; a later success clears it.
    @Test func eachSourceKeepsItsHealth() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var status = 401
        let w = WakeSources { r in r.url?.host?.hasSuffix("sentry.io") == true ? (Data("[]".utf8), status, [:]) : nil }
        _ = w.check(factories(), tokens: ("sntry", "trk"), trackerURL: Self.tracker, now: now)
        let h = w.health["/demo/pebble-puzzles"]
        #expect(h?.sentry == SourceHealth(ok: false, line: "the token was refused (401)", at: now, since: now))
        #expect(h?.tracker == SourceHealth(ok: false, line: "Tracker did not answer", at: now, since: now))
        // still failing an hour later: the same since
        let later = now.addingTimeInterval(3600)
        _ = w.check(factories(), tokens: ("sntry", nil), trackerURL: nil, now: later)
        #expect(w.health["/demo/pebble-puzzles"]?.sentry?.since == now && w.health["/demo/pebble-puzzles"]?.sentry?.at == later)
        // works again
        status = 200
        _ = w.check(factories(), tokens: ("sntry", nil), trackerURL: nil, now: later)
        #expect(w.health["/demo/pebble-puzzles"]?.sentry == SourceHealth(ok: true, line: "Works", at: later, since: nil))
        // the first failure is news once, so the app can tell you
        #expect(SourceHealth(ok: false, line: "x", at: later, since: later).isNewFailure && !SourceHealth(ok: false, line: "x", at: later, since: now).isNewFailure)
    }

    @Test func aPausedHeartbeatAsksNothing() {
        let fake = Fake(), w = WakeSources(transport: fake.transport)
        _ = w.check(factories(hb: Heartbeat(paused: true)), tokens: ("sntry", "trk"), trackerURL: Self.tracker)
        #expect(fake.asked.isEmpty)
    }
}

/// The Test button: does a token read what the factories name?
@Suite struct TokenTestTests {
    func src(_ s: String) -> FactorySources { FactoryText.sources(s) }

    @Test func sentryReadsEachNamedProject() {
        let seen = TestLog()
        let ws = WakeSources { r in seen.add(r.url!.absoluteString + " " + (r.value(forHTTPHeaderField: "Authorization") ?? "")); return (Data("{}".utf8), 200, [:]) }
        let r = ws.testSentry(token: "t0k", projects: [src("sentry: demo-org/pebble-app\nsentry-host: de.sentry.io\n")])
        #expect(r.ok && r.line == "Works: reads demo-org/pebble-app")
        #expect(seen.items == ["https://de.sentry.io/api/0/projects/demo-org/pebble-app/ Bearer t0k"])
    }

    @Test func sentrySaysWhyItFailed() {
        let refused = WakeSources { _ in (Data(), 401, [:]) }
        #expect(refused.testSentry(token: "x", projects: [src("sentry: demo-org/app\n")]) == (false, "demo-org/app: the token was refused (401)"))
        let hidden = WakeSources { _ in (Data(), 404, [:]) }
        #expect(hidden.testSentry(token: "x", projects: [src("sentry: demo-org/app\n")]).line.contains("404"))
        let silent = WakeSources { _ in nil }
        #expect(!silent.testSentry(token: "x", projects: [src("sentry: demo-org/app\n")]).ok)
        // no factory names a project: the API root says whether the token is taken
        let root = WakeSources { r in r.url!.absoluteString == "https://sentry.io/api/0/" ? (Data("{}".utf8), 200, [:]) : nil }
        #expect(root.testSentry(token: "x", projects: []).ok)
    }

    @Test func trackerSaysHelloOrReadsTheProjects() {
        let ok = WakeSources { r in
            let body = String(decoding: r.httpBody ?? Data(), as: UTF8.self)
            if body.contains("initialize") { return (Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}"#.utf8), 200, ["mcp-session-id": "s1"]) }
            if body.contains("list_stories") { return (Data(#"{"jsonrpc":"2.0","id":2,"result":{"structuredContent":{"items":[]}}}"#.utf8), 200, [:]) }
            return (Data("{}".utf8), 202, [:])
        }
        #expect(ok.testTracker(token: "x", slugs: [], url: WakeSourcesTests.tracker).ok)
        #expect(ok.testTracker(token: "x", slugs: ["pebble"], url: WakeSourcesTests.tracker) == (true, "Works: reads pebble"))
        let refused = WakeSources { _ in (Data(), 401, [:]) }
        #expect(!refused.testTracker(token: "x", slugs: [], url: WakeSourcesTests.tracker).ok && !refused.testTracker(token: "x", slugs: ["pebble"], url: WakeSourcesTests.tracker).ok)
    }

    /// Tracker is reached at the address you give it in Settings.
    @Test func trackerTalksToItsMCPEndpoint() {
        let seen = TestLog()
        let ws = WakeSources { r in seen.add(r.url!.absoluteString); return (Data(), 401, [:]) }
        _ = ws.testTracker(token: "x", slugs: [], url: URL(string: "https://tracker.example.com/mcp")!)
        #expect(seen.items == ["https://tracker.example.com/mcp"])
        #expect(ws.testTracker(token: "x", slugs: [], url: nil) == (false, "Add Tracker's MCP address first"))
    }

    @Test func trackerSaysWhyItFailed() {
        #expect(WakeSources { _ in (Data(), 401, [:]) }.testTracker(token: "x", slugs: [], url: WakeSourcesTests.tracker) == (false, "Tracker: the token was refused (401)"))
        #expect(WakeSources { _ in (Data(), 405, [:]) }.testTracker(token: "x", slugs: ["pebble"], url: WakeSourcesTests.tracker) == (false, "Tracker: answered 405"))
        #expect(WakeSources { _ in nil }.testTracker(token: "x", slugs: [], url: WakeSourcesTests.tracker) == (false, "Tracker did not answer"))
        // the server takes the token but the tool refuses: say what it said
        let unknown = WakeSources { r in
            let body = String(decoding: r.httpBody ?? Data(), as: UTF8.self)
            if body.contains("initialize") { return (Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8), 200, [:]) }
            if body.contains("list_stories") {
                return (Data(#"{"jsonrpc":"2.0","id":2,"result":{"isError":true,"content":[{"type":"text","text":"Project not found: pebble"}]}}"#.utf8), 200, [:])
            }
            return (Data(), 202, [:])
        }
        #expect(unknown.testTracker(token: "x", slugs: ["pebble"], url: WakeSourcesTests.tracker) == (false, "pebble: Project not found: pebble"))
    }
}

final class TestLog: @unchecked Sendable {
    private let lock = NSLock(); private var list: [String] = []
    func add(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
    var items: [String] { lock.lock(); defer { lock.unlock() }; return list }
}
