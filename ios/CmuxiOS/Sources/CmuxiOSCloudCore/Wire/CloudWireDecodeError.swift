import Foundation

/// A Cloud value the client cannot read.
public enum CloudWireDecodeError: Error, Hashable, Sendable {
    case unknownStatus(String)
    case unknownService(String)
    case invalidServices
    case invalidLinkToken
    case missing(String)
}
