import Darwin
import Foundation
import Testing

@Suite struct SSHPTYAttachReconnectInputFilterTests {
    @Test func keepsFilteringAcrossProbeOnlyReadsUntilFirstNormalInput() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        #expect(filter.filter(Data("\u{1B}[1;1R\u{1B}[?1;2c\u{1B}[?0u".utf8)) == Data())
        #expect(filter.filter(Data("\u{1B}]11;rgb:e5e5/e9e9/f0f0\u{07}".utf8)) == Data())
        #expect(filter.filter(Data("\u{1B}]12;rgb:ffff/ffff/ffff\u{07}".utf8)) == Data())

        let normalInput = Data("printf keep\n".utf8)
        #expect(filter.filter(normalInput) == normalInput)

        let laterReply = Data("\u{1B}[2;2R".utf8)
        #expect(filter.filter(laterReply) == laterReply)
    }

    @Test func keepsFilteringAtIdleProbeBoundaryUntilNormalInput() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        #expect(filter.filter(Data("\u{1B}[1;1R".utf8)) == Data())
        #expect(filter.isFilteringAtProbeBoundary)

        let liveReply = Data("\u{1B}[2;2R".utf8)
        #expect(filter.filter(liveReply) == Data())

        let normalInput = Data("printf keep\n".utf8)
        #expect(filter.filter(normalInput) == normalInput)
        #expect(filter.filter(liveReply) == liveReply)
    }

    @Test func stopFilteringPreservesLaterProbeLikeInput() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        #expect(filter.filter(Data("\u{1B}[1;1R".utf8)) == Data())
        #expect(filter.stopFiltering() == Data())

        let liveReply = Data("\u{1B}[2;2R".utf8)
        #expect(filter.filter(liveReply) == liveReply)
    }

    @Test func buffersRecognizedSplitOSCColorReplyWithinInitialDrain() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        #expect(filter.filter(Data("\u{1B}]11;rgb:e5e5/e9e9".utf8)) == Data())

        let normalInput = Data("printf keep\n".utf8)
        #expect(filter.filter(Data("/f0f0\u{1B}\\".utf8) + normalInput) == normalInput)
    }

    @Test func buffersOSCColorReplySplitBeforeCommandSeparator() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        #expect(filter.filter(Data("\u{1B}]1".utf8)) == Data())
        #expect(filter.filter(Data("2".utf8)) == Data())

        let normalInput = Data("printf keep\n".utf8)
        #expect(filter.filter(Data(";rgb:e5e5/e9e9/f0f0\u{07}".utf8) + normalInput) == normalInput)
    }

    @Test func buffersInitialEscapeUntilProbeContinuationArrives() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        let escape = Data([0x1B])
        #expect(filter.filter(escape) == Data())

        let normalInput = Data("printf keep\n".utf8)
        #expect(filter.filter(Data("]11;rgb:e5e5/e9e9/f0f0\u{07}".utf8) + normalInput) == normalInput)
    }

    @Test func passesThroughAmbiguousEscapeAfterNonProbeContinuation() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        let escape = Data([0x1B])
        #expect(filter.filter(escape) == Data())
        #expect(filter.filter(Data("x".utf8)) == Data("\u{1B}x".utf8))

        let keyInput = Data("\u{1B}[13;2u".utf8)
        #expect(filter.filter(keyInput) == keyInput)
    }

    @Test func flushesPendingInputWhenNoContinuationArrives() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        let escape = Data([0x1B])
        #expect(filter.filter(escape) == Data())
        #expect(filter.hasPendingInput)
        #expect(filter.flushPendingInput() == escape)

        let keyInput = Data("\u{1B}[13;2u".utf8)
        #expect(filter.filter(keyInput) == keyInput)
    }

    @Test func stdinPumpKeepsFilteringLateProbeRepliesAfterInitialDrain() throws {
        var inputPipe = [Int32](repeating: -1, count: 2)
        try makePipe(&inputPipe)
        var bridgePair = [Int32](repeating: -1, count: 2)
        try makeSocketPair(&bridgePair)
        defer {
            closeIfOpen(inputPipe[0])
            closeIfOpen(inputPipe[1])
            closeIfOpen(bridgePair[0])
            closeIfOpen(bridgePair[1])
        }

        try writeAll(fd: inputPipe[1], data: Data("\u{1B}[1;1R".utf8))
        let control = try SSHPTYAttachReconnectInputFilter.startStdinPump(
            fd: bridgePair[0],
            inputFD: inputPipe[0],
            filterEnabled: true
        )
        #expect(control != nil)

        let lateProbeReply = Data("\u{1B}]11;rgb:e5e5/e9e9/f0f0\u{07}".utf8)
        let forwardedInput = Data("printf keep\n".utf8)
        try writeAll(fd: inputPipe[1], data: lateProbeReply + forwardedInput)
        Darwin.close(inputPipe[1])
        inputPipe[1] = -1

        #expect(try readUntilEOF(fd: bridgePair[1]) == forwardedInput)
    }

    @Test func stdinPumpFiltersReadyInputBeforeStopSignal() throws {
        var inputPipe = [Int32](repeating: -1, count: 2)
        try makePipe(&inputPipe)
        var bridgePair = [Int32](repeating: -1, count: 2)
        try makeSocketPair(&bridgePair)
        defer {
            closeIfOpen(inputPipe[0])
            closeIfOpen(inputPipe[1])
            closeIfOpen(bridgePair[0])
            closeIfOpen(bridgePair[1])
        }

        let control = try SSHPTYAttachReconnectInputFilter.startStdinPump(
            fd: bridgePair[0],
            inputFD: inputPipe[0],
            filterEnabled: true
        )
        #expect(control != nil)

        let lateProbeReply = Data("\u{1B}[1;1R".utf8)
        let forwardedInput = Data("printf keep\n".utf8)
        try writeAll(fd: inputPipe[1], data: lateProbeReply + forwardedInput)
        control?.stopFiltering()
        Darwin.close(inputPipe[1])
        inputPipe[1] = -1

        #expect(try readUntilEOF(fd: bridgePair[1]) == forwardedInput)
    }

    @Test func stdinPumpStopsFilteringBeforeStopFilteringReturns() throws {
        var inputPipe = [Int32](repeating: -1, count: 2)
        try makePipe(&inputPipe)
        var bridgePair = [Int32](repeating: -1, count: 2)
        try makeSocketPair(&bridgePair)
        defer {
            closeIfOpen(inputPipe[0])
            closeIfOpen(inputPipe[1])
            closeIfOpen(bridgePair[0])
            closeIfOpen(bridgePair[1])
        }

        let control = try SSHPTYAttachReconnectInputFilter.startStdinPump(
            fd: bridgePair[0],
            inputFD: inputPipe[0],
            filterEnabled: true
        )
        #expect(control != nil)

        control?.stopFiltering()
        let liveProbeReply = Data("\u{1B}[2;2R".utf8)
        try writeAll(fd: inputPipe[1], data: liveProbeReply)
        Darwin.close(inputPipe[1])
        inputPipe[1] = -1

        #expect(try readUntilEOF(fd: bridgePair[1]) == liveProbeReply)
    }

    @Test func stdinPumpAcknowledgesAfterFilteringNaturallyEnds() throws {
        var inputPipe = [Int32](repeating: -1, count: 2)
        try makePipe(&inputPipe)
        var bridgePair = [Int32](repeating: -1, count: 2)
        try makeSocketPair(&bridgePair)
        defer {
            closeIfOpen(inputPipe[0])
            closeIfOpen(inputPipe[1])
            closeIfOpen(bridgePair[0])
            closeIfOpen(bridgePair[1])
        }

        let control = try SSHPTYAttachReconnectInputFilter.startStdinPump(
            fd: bridgePair[0],
            inputFD: inputPipe[0],
            filterEnabled: true
        )
        #expect(control != nil)

        let normalInput = Data("printf keep\n".utf8)
        try writeAll(fd: inputPipe[1], data: normalInput)
        #expect(try readExactly(fd: bridgePair[1], count: normalInput.count) == normalInput)

        control?.stopFiltering()
        let liveProbeReply = Data("\u{1B}[3;3R".utf8)
        try writeAll(fd: inputPipe[1], data: liveProbeReply)
        Darwin.close(inputPipe[1])
        inputPipe[1] = -1

        #expect(try readUntilEOF(fd: bridgePair[1]) == liveProbeReply)
    }

    private func makePipe(_ fds: inout [Int32]) throws {
        guard Darwin.pipe(&fds) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func makeSocketPair(_ fds: inout [Int32]) throws {
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = rawBuffer.count
            var cursor = base
            while remaining > 0 {
                let written = Darwin.write(fd, cursor, remaining)
                if written > 0 {
                    remaining -= written
                    cursor = cursor.advanced(by: written)
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    private func readUntilEOF(fd: Int32) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return output
            } else if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private func readExactly(fd: Int32, count expectedCount: Int) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while output.count < expectedCount {
            let remaining = expectedCount - output.count
            let count = Darwin.read(fd, &buffer, min(buffer.count, remaining))
            if count > 0 {
                output.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return output
            } else if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return output
    }

    private func closeIfOpen(_ fd: Int32) {
        guard fd >= 0 else {
            return
        }
        Darwin.close(fd)
    }
}
