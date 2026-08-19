/// Orders discovered routes without opening or inspecting a transport.
public struct TransportSelectionPolicy: Equatable, Sendable {
    /// Restricts automatic ordering or permits one explicit route family.
    public enum Mode: Equatable, Sendable {
        /// Try all discovered kinds in the configured preference order.
        case automatic

        /// Try only routes of this kind, with no silent fallback to another kind.
        case restricted(TransportKind)
    }

    /// Policy-construction failures.
    public enum Failure: Error, Equatable, Sendable {
        /// The preference list was empty or contained a duplicate kind.
        case invalidPreference
    }

    /// The selected policy mode.
    public let mode: Mode

    /// The preference order used by automatic mode.
    public let preference: [TransportKind]

    /// Creates a deterministic route-ordering policy.
    ///
    /// - Parameters:
    ///   - mode: Automatic preference or a restricted route family.
    ///   - preference: Unique route kinds in descending preference order.
    ///     The default favors Iroh, then Tailscale, then loopback.
    /// - Throws: ``Failure/invalidPreference`` for an empty or duplicate list.
    public init(
        mode: Mode = .automatic,
        preference: [TransportKind] = [.iroh, .tailscale, .loopback]
    ) throws {
        guard !preference.isEmpty,
              Set(preference).count == preference.count
        else {
            throw Failure.invalidPreference
        }
        self.mode = mode
        self.preference = preference
    }

    /// Returns routes in the only order the dialer may attempt them.
    ///
    /// Automatic mode retains discovery order within each preference rank.
    /// Kinds omitted from the preference list are retained after known kinds,
    /// which keeps future route kinds visible instead of silently dropping them.
    /// Restricted mode filters every other kind out.
    ///
    /// - Parameter routes: Discovered route descriptors.
    /// - Returns: A deterministic, policy-compliant route list.
    public func orderedRoutes(from routes: [TransportRoute]) -> [TransportRoute] {
        switch mode {
        case .restricted(let kind):
            return routes.filter { $0.kind == kind }

        case .automatic:
            let ranks = Dictionary(
                uniqueKeysWithValues: preference.enumerated().map { ($1, $0) }
            )
            return routes
                .enumerated()
                .sorted { left, right in
                    let leftRank = ranks[left.element.kind] ?? preference.count
                    let rightRank = ranks[right.element.kind] ?? preference.count
                    guard leftRank == rightRank else {
                        return leftRank < rightRank
                    }
                    return left.offset < right.offset
                }
                .map(\.element)
        }
    }
}
