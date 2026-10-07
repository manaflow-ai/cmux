/// Why a device name was rejected.
public enum DeviceNameProblem: Hashable, Sendable {
    case empty
    case tooLong(limit: Int)
    case controlCharacters
}
