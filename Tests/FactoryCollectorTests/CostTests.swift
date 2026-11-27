import Foundation
import Testing
@testable import FactoryCollector
import FactoryCore

/// D61: what work would have cost at API prices. Made-up session files only.
@Suite struct CostTests {
    private func tempHome() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("meatproxy-cost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func write(_ lines: [[String: Any]], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try text.write(wholeTo: url)
    }

    private func append(_ lines: [[String: Any]], to url: URL) throws {
        let fh = try FileHandle(forWritingTo: url); defer { try? fh.close() }
        try fh.seekToEnd()
        for l in lines { try fh.write(contentsOf: try JSONSerialization.data(withJSONObject: l)); try fh.write(contentsOf: Data([10])) }
    }

    private var stamp: String { ISO8601DateFormatter().string(from: Date()) }

    private func claudeMessage(_ id: String, model: String = "claude-opus-5-5", input: Int = 0, write: Int = 0, write1h: Int = 0, read: Int = 0, output: Int = 0) -> [String: Any] {
        ["type": "assistant", "cwd": "/demo/shopfront", "timestamp": stamp,
         "message": ["id": id, "model": model,
                     "usage": ["input_tokens": input, "cache_creation_input_tokens": write, "cache_read_input_tokens": read, "output_tokens": output,
                               "cache_creation": ["ephemeral_5m_input_tokens": write - write1h, "ephemeral_1h_input_tokens": write1h]]]]
    }

    @Test func claudePricesFollowTheModelTable() {
        // Opus 5.5: $4 in, $20 out, $0.20 cache read, writes 1.25× and 2× input
        let u = TokenUsage(input: 1_000_000, cacheWriteShort: 1_000_000, cacheWriteLong: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        #expect(abs(ApiPrices.cost(model: "claude-opus-5-5", u)! - (4 + 5 + 8 + 0.2 + 20)) < 1e-9)
        // the most specific name wins: Opus 5 is not Opus 5.5
        #expect(ApiPrices.cost(model: "claude-opus-5", TokenUsage(input: 1_000_000)) == 5)
        #expect(ApiPrices.cost(model: "claude-sonnet-5-5[1m]", TokenUsage(output: 1_000_000)) == 10)
        // fast mode is twice the price
        #expect(ApiPrices.cost(model: "claude-opus-5-5", TokenUsage(output: 1_000_000, fast: true)) == 40)
        // an unknown model is unpriced, never free
        #expect(ApiPrices.cost(model: "codex-auto-review", TokenUsage(input: 10)) == nil)
    }

    @Test func longContextUsesTheDearerRate() {
        // GPT-6.1 Sol above 272K input: $4 in instead of $2
        let short = TokenUsage(input: 200_000)
        #expect(abs(ApiPrices.cost(model: "gpt-6.1-sol", short)! - 0.4) < 1e-9)
        #expect(abs(ApiPrices.cost(model: "gpt-6.1-sol", short, prompt: 300_000)! - 0.8) < 1e-9)
        // Haiku 5.5 above 100K
        #expect(abs(ApiPrices.cost(model: "claude-haiku-5-5", TokenUsage(input: 150_000))! - 0.075) < 1e-9)
    }

    @Test func claudeSessionCountsEachMessageOnceAndKeepsReadingNewLines() throws {
        let home = try tempHome()
        let file = home.appendingPathComponent(".claude/projects/-demo-shopfront/aaaaaaaa-0000-0000-0000-000000000001.jsonl")
        // one API message is written as two lines with the same id: count it once
        try write([["type": "user", "cwd": "/demo/shopfront", "timestamp": stamp],
                   claudeMessage("msg_1", output: 1_000_000), claudeMessage("msg_1", output: 1_000_000)], to: file)
        let ledger = CostLedger(home: home, store: nil)
        ledger.update()
        var c = ledger.costs { c, _ in c }["/demo/shopfront"]
        #expect(abs((c?.today ?? 0) - 20) < 1e-9)
        // appended lines are read on the next pass, the old ones not again
        try append([claudeMessage("msg_2", input: 1_000_000)], to: file)
        ledger.update()
        c = ledger.costs { c, _ in c }["/demo/shopfront"]
        #expect(abs((c?.today ?? 0) - 24) < 1e-9)
        #expect(abs((c?.week ?? 0) - 24) < 1e-9)
    }

    @Test func subAgentsCountForTheirSessionsFolder() throws {
        let home = try tempHome()
        let sub = home.appendingPathComponent(".claude/projects/-demo-shopfront/aaaaaaaa-0000-0000-0000-000000000002/subagents/agent-1.jsonl")
        try write([claudeMessage("msg_s", model: "claude-sonnet-5-5", output: 1_000_000)], to: sub)
        let ledger = CostLedger(home: home, store: nil)
        ledger.update()
        #expect(abs((ledger.costs { c, _ in c }["/demo/shopfront"]?.today ?? 0) - 10) < 1e-9)
    }

    @Test func codexCountsTheGrowthOfItsTotalsOnce() throws {
        let home = try tempHome()
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"
        let file = home.appendingPathComponent(".codex/sessions/\(f.string(from: Date()))/rollout-demo.jsonl")
        func count(_ input: Int, cached: Int, output: Int) -> [String: Any] {
            ["type": "event_msg", "timestamp": stamp, "payload": ["type": "token_count", "info": [
                "total_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": 0, "output_tokens": output],
                "last_token_usage": ["input_tokens": 1000]]]]
        }
        try write([["type": "session_meta", "timestamp": stamp, "payload": ["cwd": "/demo/harbor-api"]],
                   ["type": "turn_context", "timestamp": stamp, "payload": ["cwd": "/demo/harbor-api", "model": "gpt-6.1-sol"]],
                   count(100_000, cached: 0, output: 0),
                   count(100_000, cached: 0, output: 0),          // the same count again: nothing new
                   count(200_000, cached: 100_000, output: 10_000)], to: file)
        let ledger = CostLedger(home: home, store: nil)
        ledger.update()
        // 100K uncached ($0.20) + 100K cached ($0.01) + 10K out ($0.10), all under the long-context line
        #expect(abs((ledger.costs { c, _ in c }["/demo/harbor-api"]?.today ?? 0) - 0.31) < 1e-9)
    }

    @Test func unknownModelsAreUnpricedAndTheSumsSurviveARestart() throws {
        let home = try tempHome(), store = home.appendingPathComponent("ledger.json")
        let file = home.appendingPathComponent(".claude/projects/-demo-tide/aaaaaaaa-0000-0000-0000-000000000003.jsonl")
        try write([claudeMessage("m1", model: "claude-future-9", output: 500), claudeMessage("m2", output: 1_000_000)], to: file)
        CostLedger(home: home, store: store).update()
        let again = CostLedger(home: home, store: store)
        let c = again.costs { _, _ in "/demo/tide" }["/demo/tide"]
        #expect(abs((c?.month ?? 0) - 20) < 1e-9)
        #expect(c?.unpricedTokens == 500)
    }

    @Test func formatsDollars() {
        #expect(ProjectCost.format(0) == "$0")
        #expect(ProjectCost.format(0.004) == "<$0.01")
        #expect(ProjectCost.format(12.4) == "$12.40")
        #expect(ProjectCost.format(1240) == "$1,240")
    }
}
