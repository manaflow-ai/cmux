/// Why a rename or removal did not happen. Nothing is queued in any case.
public enum DeviceActionError: Error, Hashable, Sendable {
    /// The registry is not live; the change was not sent.
    case offline
    /// The owner refused, with its reason.
    case refused(reason: String)
    case invalidName(DeviceNameProblem)
    /// This device is removed by signing out, not from the list.
    case cannotRemoveThisDevice
    case notFound
}
