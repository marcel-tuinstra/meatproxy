import Foundation
import Testing
@testable import FactoryCollector
import FactoryCore

/// Meatproxy without a window (`meatproxy-core`, and the Mac app's `--dump`): the same text on every platform.
@Suite struct HeadlessTests {
    @Test func theDumpShowsTowersFloorsChatsAndWhatWaitsForYou() throws {
        let world = Fixture.world()
        let lines = Headless.dump(world)
        #expect(lines.first == "Claude: \(world.building(.claude)?.projects.count ?? 0) floor(s)")
        #expect(lines.contains { $0.hasPrefix("  proj Shopfront  [") } && lines.contains { $0.hasPrefix("  chat Chats  [") })
        #expect(lines.contains { $0.contains(" waiting ") && $0.hasSuffix("Fix flaky checkout test") })
        #expect(lines.contains { $0.hasPrefix("Factory Pebble Puzzles: ") })
        // Needs you: the count, then one line for each thing, in the app's order (factories before chats)
        let needs = world.needsYou
        let at = try #require(lines.firstIndex(of: "Needs you: \(needs.count)"))
        let listed = Array(lines[(at + 1)...])
        #expect(listed.count == needs.count && !needs.isEmpty)
        #expect(listed.first?.hasPrefix("  Factories   Pebble Puzzles: ") == true)
        #expect(listed.last?.hasPrefix("  Chats       ") == true)
    }

    @Test func aModeRunsAndAnythingElseIsLeftToTheApp() {
        var out: [String] = []
        #expect(Headless.run(["meatproxy-core", "--dump", "--fixture"], out: { out.append($0) }) == 0)
        #expect(out.first?.hasPrefix("Claude: ") == true && out.contains { $0.hasPrefix("Needs you: ") })
        // no mode asked for: nil, so the Mac app opens its window
        #expect(Headless.run(["Meatproxy"], out: { _ in }) == nil)
        #expect(Headless.run(["Meatproxy", "--fixture"], out: { _ in }) == nil)
    }

    @Test func columnsArePaddedOrCut() {
        #expect(Headless.pad("Claude", 8) == "Claude  ")
        #expect(Headless.pad("working", 8) == "working ")
        #expect(Headless.pad("A very long project name", 6) == "A very")
        #expect(Headless.usage.contains("--dump") && Headless.usage.contains("--heartbeat"))
    }
}
