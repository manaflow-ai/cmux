import Foundation
import OwlMojoBindingsGeneratorCore

private struct Options {
    var mojomPath: String = ""
    var swiftOutputPath: String = ""
    var reportOutputPath: String?
    var check = false
}

private enum ToolError: Error, CustomStringConvertible {
    case usage(String)
    case io(String)
    case outOfDate(String)

    var description: String {
        switch self {
        case .usage(let message), .io(let message), .outOfDate(let message):
            return message
        }
    }
}

@main
struct OwlMojoBindingsGenerator {
    static func main() {
        do {
            let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
            try run(options: options)
        } catch let error as ToolError {
            fputs("error: \(error.description)\n", stderr)
            exit(1)
        } catch let error as MojoParserError {
            fputs("error: \(error.description)\n", stderr)
            exit(1)
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func parseOptions(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--mojom":
                index += 1
                guard index < arguments.count else {
                    throw ToolError.usage("missing value for --mojom")
                }
                options.mojomPath = arguments[index]
            case "--swift-out":
                index += 1
                guard index < arguments.count else {
                    throw ToolError.usage("missing value for --swift-out")
                }
                options.swiftOutputPath = arguments[index]
            case "--report-out":
                index += 1
                guard index < arguments.count else {
                    throw ToolError.usage("missing value for --report-out")
                }
                options.reportOutputPath = arguments[index]
            case "--check":
                options.check = true
            case "--help":
                print("""
                Usage: OwlMojoBindingsGenerator --mojom <path> --swift-out <path> [--report-out <path>] [--check]
                """)
                exit(0)
            default:
                throw ToolError.usage("unknown argument: \(argument)")
            }
            index += 1
        }

        guard !options.mojomPath.isEmpty else {
            throw ToolError.usage("missing --mojom")
        }
        guard !options.swiftOutputPath.isEmpty else {
            throw ToolError.usage("missing --swift-out")
        }
        return options
    }

    private static func run(options: Options) throws {
        let sourceURL = URL(fileURLWithPath: options.mojomPath)
        let swiftURL = URL(fileURLWithPath: options.swiftOutputPath)
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let file = try MojoParser.parse(source: source)
        let result = MojoSwiftGenerator.generate(file: file, source: source)

        let status: BindingsReportStatus
        if options.check {
            let existing = try String(contentsOf: swiftURL, encoding: .utf8)
            if existing == result.swift {
                status = .passed
            } else {
                status = .failed("Generated Swift bindings are not up to date.")
            }
        } else {
            try createParentDirectory(for: swiftURL)
            try result.swift.write(to: swiftURL, atomically: true, encoding: .utf8)
            status = .generated
        }

        if let reportOutputPath = options.reportOutputPath {
            let reportURL = URL(fileURLWithPath: reportOutputPath)
            try createParentDirectory(for: reportURL)
            let report = BindingsReportRenderer.render(
                file: file,
                result: result,
                status: status,
                mojomPath: options.mojomPath,
                swiftPath: options.swiftOutputPath
            )
            try report.write(to: reportURL, atomically: true, encoding: .utf8)
        }

        switch status {
        case .generated:
            print("Generated Swift bindings: \(options.swiftOutputPath)")
            if let reportOutputPath = options.reportOutputPath {
                print("Generated binding report: \(reportOutputPath)")
            }
            print("Checksum: \(result.checksum)")
        case .passed:
            print("Generated Swift bindings are up to date")
            print("Checksum: \(result.checksum)")
        case .failed(let message):
            throw ToolError.outOfDate(message)
        }
    }

    private static func createParentDirectory(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
}
