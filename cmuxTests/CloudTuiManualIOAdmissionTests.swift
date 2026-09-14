import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct CloudTuiManualIOAdmissionTests {
    @Test func reopeningPreservesOutstandingReservations() {
        let admission = CloudTuiManualIOAdmission(maximumBytes: 10, maximumItems: 2)
        #expect(admission.reserve(4) == .reserved)
        admission.close()
        #expect(admission.reserve(1) == .closed)
        admission.reopen()
        #expect(admission.reserve(6) == .reserved)
        #expect(admission.reserve(1) == .rejected)
        #expect(admission.reserve(0) == .closed)
        admission.release(4)
        admission.release(6)
        admission.reopen()
        #expect(admission.reserve(10) == .reserved)
        admission.release(10)
    }

    @Test func emptyPayloadsStillConsumeAnItemSlot() {
        let admission = CloudTuiManualIOAdmission(maximumBytes: 10, maximumItems: 2)
        #expect(admission.reserve(0) == .reserved)
        #expect(admission.reserve(0) == .reserved)
        #expect(admission.reserve(0) == .rejected)
    }

    @Test func concurrentCallbacksCannotOverbookOrRepeatTheRejection() async {
        let admission = CloudTuiManualIOAdmission(maximumBytes: 128, maximumItems: 512)
        let outcomes = await withTaskGroup(of: CloudTuiManualIOAdmissionResult.self) { group in
            for _ in 0..<512 { group.addTask { admission.reserve(1) } }
            var values: [CloudTuiManualIOAdmissionResult] = []
            for await value in group { values.append(value) }
            return values
        }
        #expect(outcomes.filter { $0 == .reserved }.count == 128)
        #expect(outcomes.filter { $0 == .rejected }.count == 1)
        #expect(outcomes.filter { $0 == .closed }.count == 383)
        for _ in 0..<128 { admission.release(1) }
        admission.reopen()
        #expect(admission.reserve(128) == .reserved)
        admission.release(128)
    }
}
