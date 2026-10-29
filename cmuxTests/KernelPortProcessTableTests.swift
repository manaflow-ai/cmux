import CmuxCore
@testable import CmuxFoundation
import Darwin
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Kernel port process table")
struct KernelPortProcessTableTests {
    private static let noTerminalDevice = UInt32.max

    @Test("A vanished TTY does not discard the surviving panels' processes")
    func vanishedTTYKeepsSurvivingPanels() async {
        let table = KernelPortProcessTable(
            listProcesses: {
                Self.listing([
                    Self.process(pid: 123, parent: 1, terminal: 1),
                    Self.process(pid: 456, parent: 1, terminal: 2)
                ])
            },
            terminalDevice: { name in
                name == "ttys001" ? .device(1) : .absent
            }
        )

        let scan = await table.processesOnTerminals(named: ["ttys001", "ttys011"])

        #expect(scan.values == [123: "ttys001"])
        #expect(scan.completeness == .complete)
    }

    @Test("Every TTY vanishing is authoritative emptiness, not a failed scan")
    func everyTTYVanishedIsCompleteAndEmpty() async {
        // Serializes the synchronous listing seam with the assertion read.
        let listingCount = OSAllocatedUnfairLock(initialState: 0)
        let table = KernelPortProcessTable(
            listProcesses: {
                listingCount.withLock { $0 += 1 }
                return Self.listing([Self.process(pid: 123, parent: 1, terminal: 1)])
            },
            terminalDevice: { _ in .absent }
        )

        let scan = await table.processesOnTerminals(named: ["ttys011", "ttys091"])

        #expect(scan.values.isEmpty)
        #expect(scan.completeness == .complete)
        #expect(listingCount.withLock { $0 } == 0)
    }

    @Test("A TTY that exists but cannot be inspected makes the scan incomplete")
    func unreadableTTYIsIncomplete() async {
        let table = KernelPortProcessTable(
            listProcesses: {
                Self.listing([Self.process(pid: 123, parent: 1, terminal: 1)])
            },
            terminalDevice: { name in
                name == "ttys001" ? .device(1) : .unreadable
            }
        )

        let scan = await table.processesOnTerminals(named: ["ttys001", "ttys011"])
        let onlyUnreadable = await table.processesOnTerminals(named: ["ttys011"])

        // A device that exists but cannot be read is missing evidence, not
        // absence: treating it as empty would retire live ports.
        #expect(scan.values == [123: "ttys001"])
        #expect(scan.completeness == .incomplete)
        #expect(onlyUnreadable.values.isEmpty)
        #expect(onlyUnreadable.completeness == .incomplete)
    }

    @Test("A TTY registered by full device path resolves and maps back to its canonical name")
    func fullDevicePathResolvesToCanonicalName() async {
        // `registerTTY` stores whatever the shell reported, and `$(tty)` yields
        // the full device path.
        let resolvedNames = OSAllocatedUnfairLock(initialState: [String]())
        let table = KernelPortProcessTable(
            listProcesses: {
                Self.listing([
                    Self.process(pid: 123, parent: 1, terminal: 1),
                    Self.process(pid: 456, parent: 1, terminal: 11)
                ])
            },
            terminalDevice: { name in
                resolvedNames.withLock { $0.append(name) }
                switch name {
                case "ttys001": return .device(1)
                case "ttys011": return .device(11)
                default: return .absent
                }
            }
        )

        let scan = await table.processesOnTerminals(named: ["ttys001", "/dev/ttys011"])

        #expect(scan.values == [123: "ttys001", 456: "ttys011"])
        #expect(scan.completeness == .complete)
        #expect(resolvedNames.withLock { $0 } == ["ttys001", "ttys011"])
    }

    @Test("A truncated process list is incomplete for both queries")
    func truncatedListingIsIncomplete() async {
        let table = KernelPortProcessTable(
            listProcesses: {
                Self.listing(
                    [Self.process(pid: 123, parent: 1, terminal: 1)],
                    isComplete: false,
                    isTruncated: true
                )
            },
            terminalDevice: { _ in .device(1) }
        )

        let terminals = await table.processesOnTerminals(named: ["ttys001"])
        let parents = await table.parentsByPID()

        #expect(terminals.values == [123: "ttys001"])
        #expect(terminals.completeness == .incomplete)
        #expect(parents.values == [123: 1])
        #expect(parents.completeness == .incomplete)
    }

    @Test("A process that exits between listing and reading keeps the scan complete")
    func processMissingAfterListingStaysComplete() async {
        // The enumerator reports the listing as incomplete because one listed
        // PID could not be read. That PID exited, so it holds no port and
        // parents nothing: the list itself was not truncated.
        let table = KernelPortProcessTable(
            listProcesses: {
                Self.listing(
                    [Self.process(pid: 123, parent: 1, terminal: 1)],
                    isComplete: false,
                    missingProcessCount: 1
                )
            },
            terminalDevice: { _ in .device(1) }
        )

        let terminals = await table.processesOnTerminals(named: ["ttys001"])
        let parents = await table.parentsByPID()

        #expect(terminals.values == [123: "ttys001"])
        #expect(terminals.completeness == .complete)
        #expect(parents.values == [123: 1])
        #expect(parents.completeness == .complete)
    }

    @Test("An unreadable process list is incomplete, not empty evidence")
    func emptyListingIsIncomplete() async {
        let table = KernelPortProcessTable(
            listProcesses: { Self.listing([], isComplete: false) },
            terminalDevice: { _ in .device(1) }
        )

        let terminals = await table.processesOnTerminals(named: ["ttys001"])
        let parents = await table.parentsByPID()

        #expect(terminals.values.isEmpty)
        #expect(terminals.completeness == .incomplete)
        #expect(parents.values.isEmpty)
        #expect(parents.completeness == .incomplete)
    }

    @Test("Processes without a controlling terminal never match a terminal")
    func noTerminalProcessesAreIgnored() async {
        let table = KernelPortProcessTable(
            listProcesses: {
                Self.listing([
                    Self.process(pid: 123, parent: 1, terminal: Self.noTerminalDevice),
                    Self.process(pid: 456, parent: 123, terminal: 1)
                ])
            },
            terminalDevice: { name in
                name == "ttys001" ? .device(1) : .device(Self.noTerminalDevice)
            }
        )

        let terminals = await table.processesOnTerminals(named: ["ttys001", "ttys002"])
        let parents = await table.parentsByPID()

        #expect(terminals.values == [456: "ttys001"])
        #expect(terminals.completeness == .complete)
        #expect(parents.values == [123: 1, 456: 123])
    }

    @Test("Terminal devices resolve through /dev")
    func terminalDeviceLookupUsesDeviceDirectory() {
        var nullInfo = stat()
        let nullDevice: PortTerminalDeviceLookup = stat("/dev/null", &nullInfo) == 0
            ? .device(UInt32(bitPattern: nullInfo.st_rdev))
            : .unreadable

        #expect(KernelPortProcessTable.resolveTerminalDevice(named: "null") == nullDevice)
        #expect(KernelPortProcessTable.resolveTerminalDevice(named: "ttys-cmux-missing") == .absent)
        // A directory under /dev is not a terminal.
        #expect(KernelPortProcessTable.resolveTerminalDevice(named: "fd") == .absent)
    }

    @Test("The live process table maps this process to its parent")
    func liveParentsIncludeThisProcess() async {
        let parents = await KernelPortProcessTable().parentsByPID()

        #expect(parents.values[Int(getpid())] == Int(getppid()))
        #expect(parents.completeness == .complete)
    }

    private static func process(pid: Int, parent: Int, terminal: UInt32) -> proc_bsdinfo {
        var info = proc_bsdinfo()
        info.pbi_pid = UInt32(pid)
        info.pbi_ppid = UInt32(parent)
        info.e_tdev = terminal
        return info
    }

    private static func listing(
        _ processes: [proc_bsdinfo],
        isComplete: Bool = true,
        missingProcessCount: Int = 0,
        isTruncated: Bool = false
    ) -> DarwinProcessListing {
        DarwinProcessListing(
            processes: processes,
            isComplete: isComplete,
            missingProcessCount: missingProcessCount,
            isTruncated: isTruncated
        )
    }
}
