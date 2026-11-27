import Foundation
import Testing
@testable import FactoryCollector
@testable import FactoryCore

/// The team per floor (D79): how many of each profile may work at once. The CEO is always there, there is no maximum,
/// and the numbers live in mandate.yml where the CEO reads them.
@Suite struct TeamTests {
    func tempProject(_ files: [String: String] = [:]) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("team-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (rel, text) in files {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(wholeTo: u)
        }
        return root.path
    }

    @Test func theTeamIsTheCEOPlusTheSumWithNoMaximum() {
        var t = AgentTeam(["product": 1, "developer": 2, "tester": 1])
        #expect(t.size == 5)
        #expect(t.sentence == "CEO, Product, 2 Developers and Tester")
        t.set("developer", 12)
        #expect(t.size == 15)
        t.set("product", 0); t.set("tester", -1)
        #expect(t.names == ["developer"])
        #expect(AgentTeam().size == 1)
        #expect(AgentTeam().sentence == "CEO only")
        #expect(AgentTeam.campusStart.names == ["developer", "tester"])
    }

    @Test func anOwnTeamRoundTripsThroughMandateYAML() {
        var m = FactoryMandate()
        m.ownTeam = true
        m.team = AgentTeam(["product": 1, "developer": 2, "tester": 1, "reviewer": 1])
        let back = FactoryMandate.parse(m.yaml)
        #expect(back.ownTeam)
        #expect(back.team == m.team)
        #expect(m.yaml.contains("  follows: own"))
        #expect(m.yaml.contains("  developer: 2\n"))
        // the rest of the mandate is untouched by the block after it
        #expect(back.notes == m.notes && back.level == m.level)
    }

    @Test func aFloorThatFollowsTheCampusWritesTheNumbersButNotOwn() {
        var m = FactoryMandate()
        m.team = AgentTeam(["developer": 3])
        let back = FactoryMandate.parse(m.yaml)
        #expect(!back.ownTeam)
        #expect(back.team.count("developer") == 3)
        #expect(m.yaml.contains("  follows: campus"))
    }

    @Test func anOldMandateWithoutATeamFollowsTheCampusDefault() {
        let old = "level: hybrid\nrole: orchestrator\nitems:\n  ship: ask\nnotes: |\n  Keep it small.\n"
        let m = FactoryMandate.parse(old)
        #expect(!m.ownTeam)
        #expect(m.team == .campusStart)
        #expect(m.notes == "Keep it small.")
    }

    @Test func aTeamWithOnlyTheCEOStaysEmptyAfterReading() {
        var m = FactoryMandate()
        m.ownTeam = true; m.team = AgentTeam()
        let back = FactoryMandate.parse(m.yaml)
        #expect(back.ownTeam && back.team.names.isEmpty)
    }

    @Test func aProfileNameIsTheRoleExactly() {
        #expect(CastRole(subAgentType: "tester") == .tester)
        #expect(CastRole(subAgentType: "product") == .pm)
        #expect(CastRole(subAgentType: "marketing") == .marketing)
        #expect(CastRole(subAgentType: "sales") == .sales)
        #expect(CastRole(subAgentType: "devops") == .devops)
        #expect(CastRole(subAgentType: "Developer") == .dev)
        // other types keep the old guess
        #expect(CastRole(subAgentType: "code-review") == .tester)
        #expect(CastRole(subAgentType: "Explore") == .researcher)
    }

    @Test func theTeamGetsAgentFilesForItsProfilesAndNeverReplacesOne() throws {
        let root = try tempProject([".claude/agents/developer.md": "---\nname: developer\nmodel: opus\n---\nMine.\n"])
        let team = AgentTeam(["developer": 2, "tester": 1, "reviewer": 1])
        let plan = TeamFiles.plan(root: root, project: "Pebble", team: team)
        // your own profile brings its own file; the developer's is there already
        #expect(plan.map(\.path) == [".claude/agents/developer.md", ".claude/agents/tester.md"])
        #expect(plan[0].exists && !plan[1].exists)
        let tester = plan[1].text
        #expect(tester.hasPrefix("---\nname: tester\n"))
        #expect(tester.contains("tools: Read, Glob, Grep, Bash\n"))
        #expect(tester.contains("model: haiku\n"))
        #expect(tester.contains("never push"))
        let written = try FactoryScaffold.create(plan, root: root)
        #expect(written == [".claude/agents/tester.md"])
        #expect(try String(contentsOfFile: root + "/.claude/agents/developer.md", encoding: .utf8).contains("Mine."))
        let found = TeamFiles.existing(root: root)
        #expect(found["developer"] == "opus" && found["tester"] == "haiku")
        // writing them made no factory/ queue folders
        #expect(!FileManager.default.fileExists(atPath: root + "/factory"))
    }

    @Test func helpersWorkingNowAreCountedByType() {
        var s = Session(id: "s1", provider: .claude, cwd: "/p", title: "CEO run", lastAt: Date(), turnOpen: true, projectRoot: "/p")
        s.subAgents = [SubAgent(id: "a", type: "developer", summary: "", finished: false),
                       SubAgent(id: "b", type: "Developer", summary: "", finished: false),
                       SubAgent(id: "c", type: "developer", summary: "", finished: true),
                       SubAgent(id: "d", type: "tester", summary: "", finished: false)]
        let p = Project(id: "p", provider: .claude, root: "/p", name: "Pebble", isChat: false, sessions: [s])
        #expect(TeamUsage.working(p) == ["developer": 2, "tester": 1])
    }

    @Test func theCEOPromptAndPlaybookNameTheTeam() {
        let prompt = HeartbeatRunner.prompt(root: "/p", name: "Pebble", reason: .schedule(Date()))
        #expect(prompt.contains("team block"))
        #expect(FactoryScaffold.playbook(tests: []).contains("`team:` block of `mandate.yml`"))
    }

    @Test func theCampusDefaultIsKeptInProjectsJSON() throws {
        var s = ProjectSettings()
        #expect(s.defaultTeam == .campusStart)
        s.defaultTeam = AgentTeam(["research": 2])
        let back = try JSONDecoder().decode(ProjectSettings.self, from: JSONEncoder().encode(s))
        #expect(back.defaultTeam.count("research") == 2)
        let old = try JSONDecoder().decode(ProjectSettings.self, from: Data("{\"projects\": []}".utf8))
        #expect(old.defaultTeam == .campusStart)
    }

    @Test func aProfileOfYourOwnNeedsAFreeFileName() {
        let taken = AgentProfile.standard.map(\.name)
        #expect(CustomProfile.check("code-reviewer", taken: taken) == nil)
        #expect(CustomProfile.check("", taken: taken) != nil)
        #expect(CustomProfile.check("Code Reviewer", taken: taken) != nil)
        #expect(CustomProfile.check("../evil", taken: taken) != nil)
        #expect(CustomProfile.check("tester", taken: taken) != nil)
        #expect(CustomProfile.check("ceo", taken: taken) != nil)
    }

    @Test func aProfileOfYourOwnBecomesAnAgentFileWithItsAccess() throws {
        let mine = CustomProfile(name: "code-reviewer", may: "Reviews pull requests, changes nothing", model: "opus", access: .read, look: .tester)
        #expect(mine.profile.label == "Code reviewer")
        #expect(mine.profile.role == .tester)
        let root = try tempProject()
        let plan = TeamFiles.plan(root: root, project: "Pebble", team: AgentTeam(["code-reviewer": 1]), profiles: AgentProfile.standard + [mine.profile])
        #expect(plan.map(\.path) == [".claude/agents/code-reviewer.md"])
        #expect(plan[0].text.contains("tools: Read, Glob, Grep, WebSearch, WebFetch\n"))
        #expect(plan[0].text.contains("model: opus\n"))
        #expect(!plan[0].text.contains("Edit"))
        var s = ProjectSettings(); s.customProfiles = [mine]
        let back = try JSONDecoder().decode(ProjectSettings.self, from: JSONEncoder().encode(s))
        #expect(back.customProfiles == [mine])
    }

    func floor(team: AgentTeam, helpers: [SubAgent], roles: [String: CastRole] = [:]) -> Project {
        var s = Session(id: "s1", provider: .claude, cwd: "/p", title: "CEO run", lastAt: Date(), turnOpen: true, projectRoot: "/p")
        s.subAgents = helpers
        var p = Project(id: "p", provider: .claude, root: "/p", name: "Pebble", isChat: false, sessions: [s],
                        factory: FactoryText.factory(root: "/p", files: [:]))
        p.team = team; p.teamRoles = roles
        return p
    }

    @Test func everyTeamMemberHasAPlaceAndAHelperAtWorkTakesOne() {
        let p = floor(team: AgentTeam(["developer": 2, "tester": 1]), helpers: [
            SubAgent(id: "a", type: "developer", summary: "", finished: false),
            SubAgent(id: "b", type: "tester", summary: "", finished: true),
            SubAgent(id: "c", type: "developer", summary: "", finished: false),
            SubAgent(id: "d", type: "developer", summary: "", finished: false),
        ])
        let slots = p.teamSlots
        #expect(slots.map(\.id) == ["team:/p:developer:0", "team:/p:developer:1", "team:/p:tester:0"])
        // two developers at work fill both places, in the order they started; the third is extra and gets none
        #expect(slots.map(\.helper) == ["a", "c", nil])
        #expect(slots[0].owner == "s1")
        // a place keeps its face, busy or free
        #expect(slots[0].cast == CastKey(role: .dev, seed: "team:/p:developer:0"))
        #expect(p.isTeamProfile("Tester") && !p.isTeamProfile("research"))
    }

    @Test func aPlainProjectOrNoTeamHasNoPlaces() {
        var p = floor(team: AgentTeam(["developer": 1]), helpers: [])
        p.factory = nil
        #expect(p.teamSlots.isEmpty && !p.isTeamProfile("developer"))
        var q = floor(team: AgentTeam(), helpers: [])
        q.team = nil
        #expect(q.teamSlots.isEmpty)
    }

    @Test func aProfileOfYourOwnWearsTheLookYouChose() {
        let p = floor(team: AgentTeam(["code-reviewer": 1]), helpers: [], roles: ["code-reviewer": .designer])
        #expect(p.teamSlots.first?.role == .designer)
    }
}
