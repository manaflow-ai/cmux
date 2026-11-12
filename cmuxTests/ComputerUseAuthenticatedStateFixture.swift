import CryptoKit
import Foundation

/// Encodes signed state using the same fixture key for repository and runtime tests.
struct ComputerUseAuthenticatedStateFixture: Sendable {
    let authenticationKey = Data(repeating: 0x5a, count: 32)

    func data(
        driverPID: Int,
        writerPID: Int,
        writerStartSeconds: Int64,
        writerStartMicroseconds: Int64,
        session: String?,
        targetApp: String,
        targetPID: Int,
        targetWindowID: Int,
        lastActionAt: String
    ) throws -> Data {
        // Schema-4 keeps the historical wire prefix shared with the Rust
        // cmux-cua writer; the Swift type name is the part that was renamed.
        var message = Data("cmux-computer-use-state-v1\0".utf8)
        appendInteger(driverPID, to: &message)
        appendInteger(writerPID, to: &message)
        appendInteger(writerStartSeconds, to: &message)
        appendInteger(writerStartMicroseconds, to: &message)
        appendOptionalString(session, to: &message)
        appendOptionalString(targetApp, to: &message)
        appendInteger(targetPID, to: &message)
        appendInteger(targetWindowID, to: &message)
        appendString(lastActionAt, to: &message)
        appendInteger(4, to: &message)
        let code = HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: authenticationKey)
        )
        let object: [String: Any] = [
            "driver_pid": driverPID,
            "writer_pid": writerPID,
            "writer_start_seconds": writerStartSeconds,
            "writer_start_microseconds": writerStartMicroseconds,
            "session": session as Any? ?? NSNull(),
            "target_app": targetApp,
            "target_pid": targetPID,
            "target_window_id": targetWindowID,
            "last_action_at": lastActionAt,
            "schema": 4,
            "state_authentication_code": code.map {
                String(format: "%02x", $0)
            }.joined(),
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func appendInteger<T: BinaryInteger>(
        _ value: T,
        to message: inout Data
    ) {
        message.append(contentsOf: String(value).utf8)
        message.append(0)
    }

    private func appendString(_ value: String, to message: inout Data) {
        let bytes = Data(value.utf8)
        message.append(contentsOf: String(bytes.count).utf8)
        message.append(UInt8(ascii: ":"))
        message.append(bytes)
        message.append(0)
    }

    private func appendOptionalString(
        _ value: String?,
        to message: inout Data
    ) {
        guard let value else {
            message.append(contentsOf: [UInt8(ascii: "-"), 0])
            return
        }
        appendString(value, to: &message)
    }
}
