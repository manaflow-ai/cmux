import Foundation

/// A Cloud value the client cannot read.
public enum CloudWireDecodeError: Error, Hashable, Sendable {
    case unknownStatus(String)
    case missing(String)
}
