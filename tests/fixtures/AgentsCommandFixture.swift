import Foundation

// Minimal host for compiling the production agents command without AppKit or an
// app build. Every socket call is echoed to stderr so tests can assert that list
// reads never mutate and open sends exactly one surface.project.
struct CMUXCLI {
    // The real one lives in cmux.swift; no agents invocation defers its connection.
    static func commandDefersSocketConnectionUntilRequest(command: String, commandArgs: [String]) -> Bool { false }

    // Same encoding as CMUXCLI+JSONOutput.swift, which needs package modules to compile.
    func jsonString(_ object: Any, prettyPrinted: Bool = true) -> String {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if prettyPrinted { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

final class SocketClient {
    let result: [String: Any]
    init(result: [String: Any]) { self.result = result }
    func sendV2(method: String, params: [String: Any], responseTimeout: TimeInterval? = nil) throws -> [String: Any] {
        let call: [String: Any] = ["method": method, "params": params]
        FileHandle.standardError.write(Data((CMUXCLI().jsonString(call, prettyPrinted: false) + "\n").utf8))
        if method == "surface.project" { return ["surface_id": "fixture-surface", "reused": true] }
        return result
    }
}

@main
struct AgentsFixture {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "focus" {
                print(CMUXCLI.shouldFocusWindowBeforeDispatch(command: arguments[1], commandArgs: Array(arguments.dropFirst(2))))
                return
            }
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let payload = try JSONSerialization.jsonObject(with: input) as? [String: Any] ?? [:]
            try CMUXCLI().runAgentsCommand(commandArgs: arguments, client: SocketClient(result: payload), jsonOutput: false)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
