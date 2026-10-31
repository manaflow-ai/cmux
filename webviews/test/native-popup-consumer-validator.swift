import Foundation

// Compile with Overlay/Generated/NativePopup*.swift and NativePopupModel+Validation.swift.
// This exercises the same generated decoder and validator used by NativePopupHost.show.
@main
struct ConsumerValidator {
    static func main() throws {
        var count = 0
        while let line = readLine() {
            count += 1
            let model = try JSONDecoder().decode(NativePopupModel.self, from: Data(line.utf8))
            guard model.isValid else {
                FileHandle.standardError.write(Data("Invalid consumer descriptor \(count): \(line)\n".utf8))
                exit(1)
            }
        }
        guard count > 0 else { exit(2) }
        print("Validated \(count) emitted consumer descriptors")
    }
}
