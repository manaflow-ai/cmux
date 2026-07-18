import CmuxLiteCore
import Foundation

@main
struct CmuxLiteSmoke {
    static func main() async {
        do {
            let runner = try SmokeRunner(arguments: Array(CommandLine.arguments.dropFirst()))
            try await runner.runWithDeadline()
        } catch {
            FileHandle.standardError.write(Data("cmux-lite-smoke: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}
