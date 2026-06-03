import XCTest
@testable import cmux_DEV

final class TerminalSSHPrivateKeyParserTests: XCTestCase {
    func testParseUnencryptedOpenSSHEd25519PrivateKey() throws {
        let parsed = try TerminalSSHPrivateKeyParser.parse(
            TerminalSSHPrivateKeyFixtures.opensshEd25519PrivateKey
        )

        XCTAssertEqual(
            parsed.openSSHPublicKey,
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINvyNmiONArbP9h80XMMVDzfpE8TdS9h6gxrUwDacRXs"
        )
    }

    func testParseOpenSSHPrivateKeyAllowsNonUTF8Comment() throws {
        let key = try TerminalSSHPrivateKeyFixtures.ed25519PrivateKeyWithNonUTF8Comment()

        let parsed = try TerminalSSHPrivateKeyParser.parse(key)

        XCTAssertEqual(
            parsed.openSSHPublicKey,
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINvyNmiONArbP9h80XMMVDzfpE8TdS9h6gxrUwDacRXs"
        )
    }

    func testParseUnencryptedOpenSSHECDSAPrivateKeys() throws {
        let p256 = try TerminalSSHPrivateKeyParser.parse(
            TerminalSSHPrivateKeyFixtures.opensshECDSAP256PrivateKey
        )
        let p384 = try TerminalSSHPrivateKeyParser.parse(
            TerminalSSHPrivateKeyFixtures.opensshECDSAP384PrivateKey
        )
        let p521 = try TerminalSSHPrivateKeyParser.parse(
            TerminalSSHPrivateKeyFixtures.opensshECDSAP521PrivateKey
        )

        XCTAssertEqual(
            p256.openSSHPublicKey,
            "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBNmEO6M8ETjugVsjd8opfXMXlOmKh0ARoL7CC86VDjdPhYYj0a6r0hBfzHboGHJ5of+th6OY+J/uyvr01RFIAek="
        )
        XCTAssertEqual(
            p384.openSSHPublicKey,
            "ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBAHXO3CUQ7souMyT2DHOPow5RIw7nuQQ/f0mZjODb6YhbpWjJNq8pDiOOKHnop+bTpsKaoQpcA4xATOY5zH6r9uQaJiHeUJhovJhsROEIAyPsnV1f++rYq7Xxr6ewpsfIw=="
        )
        XCTAssertEqual(
            p521.openSSHPublicKey,
            "ecdsa-sha2-nistp521 AAAAE2VjZHNhLXNoYTItbmlzdHA1MjEAAAAIbmlzdHA1MjEAAACFBAC9AVrKROm/bHlHwNGqh2F3N6C/+R0Pp+JVl67nn5C1EGcgztA8jepMBJqdQZHojRjBMvf6t4Usun2kvCVfGSYvcAAJWe/UqZcNZy6d6+4UarWE2EVLCZcUjjcEDu/N1oOU3CB6LQw8g6pnMbrGJMZ5VbVlmZa9a0Jm7w7r4If2BuA2gQ=="
        )
    }

    func testRejectsEncryptedPrivateKeys() {
        let encryptedKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABDfN7L7aq
        yqTPIZ5mNc+mUhAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAINP62cDPhO7Kp7yj
        YRByvi7TxmWJ84bJH80aaEftFTFRAAAAsKd5GfeRUVQGty6jnYlKVB4N1bmAU0o57FW8MB
        dLAP+KEJEWstrqLMADio3eh/a8Ni+4PB0+/0Q5NaGFmho5F3+2sNjUIROSB1s9SmoKRr3/
        1eiVi/X/88S0XJm1aR7tdfl2pmi2KfOi/hbgwCN1tFVPkj4AFZ7X74BWdLe5YgmXEbpoMZ
        8EiJg6E7xlMeCwYXQM4sMPvf04ZGcE9l4YcsxQ8Z7MxUaCXYRMcA/iDDVd
        -----END OPENSSH PRIVATE KEY-----
        """

        XCTAssertThrowsError(try TerminalSSHPrivateKeyParser.parse(encryptedKey)) { error in
            XCTAssertEqual(
                error as? TerminalSSHPrivateKeyParserError,
                .encryptedKeysUnsupported
            )
        }
    }

    func testRejectsUnsupportedOpenSSHRSAPrivateKey() {
        XCTAssertThrowsError(
            try TerminalSSHPrivateKeyParser.parse(
                TerminalSSHPrivateKeyFixtures.opensshRSAPrivateKey
            )
        ) { error in
            XCTAssertEqual(
                error as? TerminalSSHPrivateKeyParserError,
                .unsupportedKeyType
            )
        }
    }
}

enum TerminalSSHPrivateKeyFixtures {
    static let opensshEd25519PrivateKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACDb8jZojjQK2z/YfNFzDFQ836RPE3UvYeoMa1MA2nEV7AAAALCVDAZklQwG
    ZAAAAAtzc2gtZWQyNTUxOQAAACDb8jZojjQK2z/YfNFzDFQ836RPE3UvYeoMa1MA2nEV7A
    AAAECl+h4dEXh/v1LDp8T2eIkYyzvJJ87b73vnzol+yjG1EdvyNmiONArbP9h80XMMVDzf
    pE8TdS9h6gxrUwDacRXsAAAAJmxhd3JlbmNlQGxhd3JlbmNlcy1NYWNCb29rLVByby0yLm
    xvY2FsAQIDBAUGBw==
    -----END OPENSSH PRIVATE KEY-----
    """

    static let opensshECDSAP256PrivateKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
    1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQTZhDujPBE47oFbI3fKKX1zF5TpiodA
    EaC+wgvOlQ43T4WGI9Guq9IQX8x26BhyeaH/rYejmPif7sr69NURSAHpAAAAwFBUV2xQVF
    dsAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBNmEO6M8ETjugVsj
    d8opfXMXlOmKh0ARoL7CC86VDjdPhYYj0a6r0hBfzHboGHJ5of+th6OY+J/uyvr01RFIAe
    kAAAAhAMLr+oDsSj4c9uEGbHRO2tFHvqS4hw4q2p0n1RT1LF43AAAAJmxhd3JlbmNlQGxh
    d3JlbmNlcy1NYWNCb29rLVByby0yLmxvY2FsAQ==
    -----END OPENSSH PRIVATE KEY-----
    """

    static let opensshECDSAP384PrivateKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAiAAAABNlY2RzYS
    1zaGEyLW5pc3RwMzg0AAAACG5pc3RwMzg0AAAAYQQB1ztwlEO7KLjMk9gxzj6MOUSMO57k
    EP39JmYzg2+mIW6VoyTavKQ4jjih56Kfm06bCmqEKXAOMQEzmOcx+q/bkGiYh3lCYaLyYb
    EThCAMj7J1dX/vq2Ku18a+nsKbHyMAAADwGX6D3Bl+g9wAAAATZWNkc2Etc2hhMi1uaXN0
    cDM4NAAAAAhuaXN0cDM4NAAAAGEEAdc7cJRDuyi4zJPYMc4+jDlEjDue5BD9/SZmM4Nvpi
    FulaMk2rykOI44oeein5tOmwpqhClwDjEBM5jnMfqv25BomId5QmGi8mGxE4QgDI+ydXV/
    76tirtfGvp7Cmx8jAAAAMQDneRyjeOB+FLyq8dA/5j/9hTTF3CxLLnhirJ4LS+BUdptQxj
    eismcuO8r7vrquVcQAAAAmbGF3cmVuY2VAbGF3cmVuY2VzLU1hY0Jvb2stUHJvLTIubG9j
    YWwB
    -----END OPENSSH PRIVATE KEY-----
    """

    static let opensshECDSAP521PrivateKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAArAAAABNlY2RzYS
    1zaGEyLW5pc3RwNTIxAAAACG5pc3RwNTIxAAAAhQQAvQFaykTpv2x5R8DRqodhdzegv/kd
    D6fiVZeu55+QtRBnIM7QPI3qTASanUGR6I0YwTL3+reFLLp9pLwlXxkmL3AACVnv1KmXDW
    cunevuFGq1hNhFSwmXFI43BA7vzdaDlNwgei0MPIOqZzG6xiTGeVW1ZZmWvWtCZu8O6+CH
    9gbgNoEAAAEoqDV/n6g1f58AAAATZWNkc2Etc2hhMi1uaXN0cDUyMQAAAAhuaXN0cDUyMQ
    AAAIUEAL0BWspE6b9seUfA0aqHYXc3oL/5HQ+n4lWXruefkLUQZyDO0DyN6kwEmp1BkeiN
    GMEy9/q3hSy6faS8JV8ZJi9wAAlZ79Splw1nLp3r7hRqtYTYRUsJlxSONwQO783Wg5TcIH
    otDDyDqmcxusYkxnlVtWWZlr1rQmbvDuvgh/YG4DaBAAAAQTNipD5mEfUVtvI1LOvX8GQ9
    2Tuk5B4PoOYxW/rdrBVYiI+Iqlz0/J9FOOkwAn9po2hoNxfsORwDWtIQI7euASODAAAAJm
    xhd3JlbmNlQGxhd3JlbmNlcy1NYWNCb29rLVByby0yLmxvY2FsAQIDBAU=
    -----END OPENSSH PRIVATE KEY-----
    """

    static let opensshRSAPrivateKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    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
    AQIDBA==
    -----END OPENSSH PRIVATE KEY-----
    """

    static func ed25519PrivateKeyWithNonUTF8Comment() throws -> String {
        var payload = try opensshPayload(from: opensshEd25519PrivateKey)
        var offset = try skipOpenSSHEnvelope(in: payload)

        _ = try readUInt32(in: payload, offset: &offset)
        _ = try readUInt32(in: payload, offset: &offset)
        try skipString(in: payload, offset: &offset)
        try skipString(in: payload, offset: &offset)
        try skipString(in: payload, offset: &offset)

        let commentLength = try Int(readUInt32(in: payload, offset: &offset))
        guard offset + commentLength <= payload.count else {
            throw FixtureMutationError.invalidOpenSSHPrivateKey
        }

        for index in 0..<commentLength {
            payload[offset + index] = index.isMultiple(of: 2) ? 0xFF : 0xFE
        }

        return pemString(from: payload)
    }

    private static func opensshPayload(from privateKey: String) throws -> Data {
        let lines = privateKey
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let body = lines.dropFirst().dropLast().joined()
        guard let data = Data(base64Encoded: body) else {
            throw FixtureMutationError.invalidOpenSSHPrivateKey
        }
        return data
    }

    private static func skipOpenSSHEnvelope(in payload: Data) throws -> Int {
        let magic = Data("openssh-key-v1\u{0}".utf8)
        guard payload.starts(with: magic) else {
            throw FixtureMutationError.invalidOpenSSHPrivateKey
        }

        var offset = magic.count
        try skipString(in: payload, offset: &offset)
        try skipString(in: payload, offset: &offset)
        try skipString(in: payload, offset: &offset)
        let keyCount = try readUInt32(in: payload, offset: &offset)
        guard keyCount == 1 else {
            throw FixtureMutationError.invalidOpenSSHPrivateKey
        }
        try skipString(in: payload, offset: &offset)
        return try readStringStart(in: payload, offset: &offset)
    }

    private static func skipString(in data: Data, offset: inout Int) throws {
        let length = try Int(readUInt32(in: data, offset: &offset))
        guard offset + length <= data.count else {
            throw FixtureMutationError.invalidOpenSSHPrivateKey
        }
        offset += length
    }

    private static func readStringStart(in data: Data, offset: inout Int) throws -> Int {
        let length = try Int(readUInt32(in: data, offset: &offset))
        guard offset + length <= data.count else {
            throw FixtureMutationError.invalidOpenSSHPrivateKey
        }
        return offset
    }

    private static func readUInt32(in data: Data, offset: inout Int) throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw FixtureMutationError.invalidOpenSSHPrivateKey
        }
        defer { offset += 4 }
        return data[offset..<(offset + 4)].reduce(UInt32.zero) { partialResult, byte in
            (partialResult << 8) | UInt32(byte)
        }
    }

    private static func pemString(from payload: Data) -> String {
        let base64 = payload.base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 70).map { start -> String in
            let startIndex = base64.index(base64.startIndex, offsetBy: start)
            let endIndex = base64.index(
                startIndex,
                offsetBy: min(70, base64.distance(from: startIndex, to: base64.endIndex))
            )
            return String(base64[startIndex..<endIndex])
        }
        return (["-----BEGIN OPENSSH PRIVATE KEY-----"] + lines + ["-----END OPENSSH PRIVATE KEY-----"])
            .joined(separator: "\n")
    }

    private enum FixtureMutationError: Error {
        case invalidOpenSSHPrivateKey
    }
}
