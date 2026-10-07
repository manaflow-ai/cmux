import CmuxMobileWire

// Test-only literals for JSON params.
extension JSONValue: @retroactive ExpressibleByStringLiteral, @retroactive ExpressibleByIntegerLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
}
