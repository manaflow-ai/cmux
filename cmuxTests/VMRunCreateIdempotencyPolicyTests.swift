import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct VMRunCreateIdempotencyPolicyTests {
    @Test func reuseKeepsOriginalCreationTimestamp() {
        let original = CMUXCLI.VMRunCreateIdempotencyRecord(
            key: "create-key",
            createdAt: 1_000,
            ownerPID: 11,
            uncertain: true
        )

        let reused = CMUXCLI.vmRunCreateRecordAfterReuse(original, ownerPID: 22)

        #expect(reused.key == original.key)
        #expect(reused.createdAt == original.createdAt)
        #expect(reused.ownerPID == 22)
        #expect(!reused.uncertain)
    }
}
