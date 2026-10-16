import Foundation

// Minimal host for compiling the production command and focus policy without
// AppKit/building the app. The full CLI transport is exercised by test_cli_current.
struct CMUXCLI {}

final class SocketClient {
    let result: [String: Any]
    init(result: [String: Any]) { self.result = result }
    func sendV2(method: String, params: [String: Any]) throws -> [String: Any] {
        let call: [String: Any] = ["method": method, "params": params]
        FileHandle.standardError.write(Data((CMUXCLI().jsonString(call, prettyPrinted: false) + "\n").utf8))
        return result
    }
}

@main
struct CurrentFixture {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "focus" {
                print(CMUXCLI.shouldFocusWindowBeforeDispatch(command: arguments[1], commandArgs: Array(arguments.dropFirst(2))))
                return
            }
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let payload = try JSONSerialization.jsonObject(with: input) as? [String: Any] ?? [:]
            try CMUXCLI().runCurrentCommand(commandArgs: arguments, client: SocketClient(result: payload), jsonOutput: false)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
