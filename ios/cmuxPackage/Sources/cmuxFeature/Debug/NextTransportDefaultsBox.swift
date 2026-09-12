#if DEBUG
import Foundation

/// Transfers the same preferences domain to credential persistence workers.
/// UserDefaults documents its API as thread-safe but lacks Sendable conformance;
/// the immutable reference is used only through those thread-safe API methods.
final class NextTransportDefaultsBox: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) { self.value = value }
}
#endif
