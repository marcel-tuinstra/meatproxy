import Foundation
import FactoryCore
import FactoryCollector

// meatproxy-core: Meatproxy without a window, on macOS, Linux and Windows. It runs the same modes as the Mac app's
// command line (`Meatproxy --dump`, `--costs`, `--ops`, `--heartbeat`), from the same code: `Headless`.
let arguments = CommandLine.arguments
if arguments.contains("--help") || arguments.contains("-h") { print(Headless.usage); exit(0) }
// the settings folder moved with the brand (D45); every mode reads it
if !arguments.contains("--fixture") && !arguments.contains("--first-run") { AppSupport.migrateLegacyFolder() }
if let code = Headless.run(arguments) { exit(code) }
print(Headless.usage)
exit(arguments.count > 1 ? 2 : 0)
