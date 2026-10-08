import Foundation

/// The mixed numeric/string shape emitted by the Worker for a link grant.
struct WireCloudLinkToken: Decodable {
    var token: String
    var expires_at: JSONNumberOrString
    var host: String
    var epoch: Int
    var services: [String]
}

/// Cloud revisions and expiry values have appeared as numbers and decimal
/// strings in older Worker deployments. Keep the compatibility local to this
/// decoder and reject every other shape.
enum JSONNumberOrString: Decodable {
    case number(Double)
    case string(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected number or decimal string")
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        }
    }
}
