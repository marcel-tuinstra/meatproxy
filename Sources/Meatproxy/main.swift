import Foundation
import FactoryCore
import FactoryCollector

// the settings folder moved with the brand (D45); --dump and --snapshot read it too
if !CommandLine.arguments.contains("--fixture") && !CommandLine.arguments.contains("--first-run") { AppSupport.migrateLegacyFolder() }

// The modes without a window (--dump, --watch, --costs, --ops, --heartbeat): the launch agent and the DevOps agent run
// them here; `meatproxy-core` is the same code on Linux and Windows.
if let code = Headless.run(CommandLine.arguments) { exit(code) }
if CommandLine.arguments.contains("--snapshot") {
    exit(MainActor.assumeIsolated { Snapshot.run(CommandLine.arguments) })
}
MeatproxyApp.main()
