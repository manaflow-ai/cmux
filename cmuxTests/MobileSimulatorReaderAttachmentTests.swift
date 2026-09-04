import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct MobileSimulatorReaderAttachmentTests {
    @Test func transportBeforeDisplayAttachesWhenDisplayBecomesReady() throws {
        var attachment = MobileSimulatorReaderAttachment<String>()
        var readerFactoryCalls = 0
        let transportBeforeDisplay = MobileSimulatorReaderReadiness(
            transportName: "simulator-frame",
            displayScale: nil
        )

        attachment.refresh(for: transportBeforeDisplay) {
            readerFactoryCalls += 1
            return "reader"
        }

        #expect(readerFactoryCalls == 0)
        #expect(attachment.reader == nil)

        let displayReady = try #require(MobileSimulatorReaderReadiness(
            transportName: "simulator-frame",
            displayScale: 3
        ))
        attachment.refresh(for: displayReady) {
            readerFactoryCalls += 1
            return "reader"
        }

        #expect(readerFactoryCalls == 1)
        #expect(attachment.reader == "reader")
    }

    @Test func failedReaderConstructionRemainsRetryableForSameReadiness() throws {
        var attachment = MobileSimulatorReaderAttachment<String>()
        var readerFactoryCalls = 0
        let readiness = try #require(MobileSimulatorReaderReadiness(
            transportName: "simulator-frame",
            displayScale: 3
        ))

        attachment.refresh(for: readiness) {
            readerFactoryCalls += 1
            return nil
        }

        #expect(readerFactoryCalls == 1)
        #expect(attachment.reader == nil)

        attachment.refresh(for: readiness) {
            readerFactoryCalls += 1
            return "reader"
        }

        #expect(readerFactoryCalls == 2)
        #expect(attachment.reader == "reader")

        attachment.refresh(for: readiness) {
            readerFactoryCalls += 1
            return "replacement"
        }

        #expect(readerFactoryCalls == 2)
        #expect(attachment.reader == "reader")
    }
}
