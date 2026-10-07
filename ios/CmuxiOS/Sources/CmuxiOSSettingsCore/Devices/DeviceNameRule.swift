import Foundation

/// The rename rule: trimmed, 1 to `maximumLength` characters, no control
/// characters (they would break every list that shows the name).
public struct DeviceNameRule: Hashable, Sendable {
    public var maximumLength: Int

    public init(maximumLength: Int = 64) { self.maximumLength = maximumLength }

    /// The name to send, or why it cannot be used.
    public func validate(_ raw: String) -> Result<String, DeviceNameError> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .failure(DeviceNameError(problem: .empty)) }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .failure(DeviceNameError(problem: .controlCharacters))
        }
        if name.count > maximumLength { return .failure(DeviceNameError(problem: .tooLong(limit: maximumLength))) }
        return .success(name)
    }
}
