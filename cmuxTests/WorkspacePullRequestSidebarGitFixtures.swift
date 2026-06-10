import XCTest
import Darwin
import CmuxProcess

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Git repository and index fixture writers for WorkspacePullRequestSidebarTests
func writeMinimalGitRepository(
    at repoURL: URL,
    headCommit: String = "0000000000000000000000000000000000000000",
    indexData: Data = Data()
) throws {
    let gitURL = repoURL.appendingPathComponent(".git", isDirectory: true)
    let refsURL = gitURL.appendingPathComponent("refs/heads", isDirectory: true)
    try FileManager.default.createDirectory(at: refsURL, withIntermediateDirectories: true)
    try "ref: refs/heads/main\n".write(
        to: gitURL.appendingPathComponent("HEAD"),
        atomically: true,
        encoding: .utf8
    )
    try "\(headCommit)\n".write(
        to: refsURL.appendingPathComponent("main"),
        atomically: true,
        encoding: .utf8
    )
    try indexData.write(to: gitURL.appendingPathComponent("index"))
    try """
    [remote "origin"]
        url = https://github.com/manaflow-ai/cmux.git
    """.write(
        to: gitURL.appendingPathComponent("config"),
        atomically: true,
        encoding: .utf8
    )
}

func writeEmptyGitIndex(at repoURL: URL, signatureByte: UInt8) throws {
    var data = Data()
    data.append(contentsOf: [0x44, 0x49, 0x52, 0x43])
    appendBigEndianUInt32(2, to: &data)
    appendBigEndianUInt32(0, to: &data)
    data.append(Data(repeating: signatureByte, count: 20))
    try data.write(to: repoURL.appendingPathComponent(".git/index"))
}

func writeGitIndexVersion2Entry(
    at repoURL: URL,
    trackedPath: String,
    mode: UInt32,
    size: UInt32,
    signatureByte: UInt8,
    objectIDBytes: [UInt8] = Array(repeating: 0, count: 20)
) throws {
    var data = Data()
    data.append(contentsOf: [0x44, 0x49, 0x52, 0x43])
    appendBigEndianUInt32(2, to: &data)
    appendBigEndianUInt32(1, to: &data)

    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(mode, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(size, to: &data)
    data.append(contentsOf: objectIDBytes.prefix(20))
    if objectIDBytes.count < 20 {
        data.append(Data(repeating: 0, count: 20 - objectIDBytes.count))
    }

    let pathBytes = Array(trackedPath.utf8)
    appendBigEndianUInt16(UInt16(min(pathBytes.count, 0x0fff)), to: &data)
    data.append(contentsOf: pathBytes)
    data.append(0)
    while data.count % 8 != 0 {
        data.append(0)
    }
    data.append(Data(repeating: signatureByte, count: 20))

    try data.write(to: repoURL.appendingPathComponent(".git/index"))
}

func gitObjectIDBytes(_ hex: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
        bytes.append(UInt8(hex[index..<nextIndex], radix: 16) ?? 0)
        index = nextIndex
    }
    return bytes
}

func writeGitIndexVersion3SkipWorktreeEntry(
    at repoURL: URL,
    trackedPath: String,
    signatureByte: UInt8
) throws {
    var data = Data()
    data.append(contentsOf: [0x44, 0x49, 0x52, 0x43])
    appendBigEndianUInt32(3, to: &data)
    appendBigEndianUInt32(1, to: &data)

    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0o100644, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    appendBigEndianUInt32(0, to: &data)
    data.append(Data(repeating: 0, count: 20))

    let pathBytes = Array(trackedPath.utf8)
    appendBigEndianUInt16(UInt16(min(pathBytes.count, 0x0fff)) | 0x4000, to: &data)
    appendBigEndianUInt16(0x4000, to: &data)
    data.append(contentsOf: pathBytes)
    data.append(0)
    while data.count % 8 != 0 {
        data.append(0)
    }
    data.append(Data(repeating: signatureByte, count: 20))

    try data.write(to: repoURL.appendingPathComponent(".git/index"))
}

func writeGitIndexVersion2EntryFromStat(
    at repoURL: URL,
    trackedPath: String,
    indexMode: UInt32,
    signatureByte: UInt8,
    objectIDBytes: [UInt8] = Array(repeating: 0, count: 20),
    baseFlags: UInt16 = 0
) throws {
    let fileURL = repoURL.appendingPathComponent(trackedPath)
    var statValue = stat()
    guard lstat(fileURL.path, &statValue) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
    }

    var data = Data()
    data.append(contentsOf: [0x44, 0x49, 0x52, 0x43])
    appendBigEndianUInt32(2, to: &data)
    appendBigEndianUInt32(1, to: &data)

    appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_ctimespec.tv_sec), to: &data)
    appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_ctimespec.tv_nsec), to: &data)
    appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_mtimespec.tv_sec), to: &data)
    appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_mtimespec.tv_nsec), to: &data)
    appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_dev), to: &data)
    appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_ino), to: &data)
    appendBigEndianUInt32(indexMode, to: &data)
    appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_uid), to: &data)
    appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_gid), to: &data)
    appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_size), to: &data)
    data.append(contentsOf: objectIDBytes.prefix(20))
    if objectIDBytes.count < 20 {
        data.append(Data(repeating: 0, count: 20 - objectIDBytes.count))
    }

    let pathBytes = Array(trackedPath.utf8)
    appendBigEndianUInt16(UInt16(min(pathBytes.count, 0x0fff)) | baseFlags, to: &data)
    data.append(contentsOf: pathBytes)
    data.append(0)
    while data.count % 8 != 0 {
        data.append(0)
    }
    data.append(Data(repeating: signatureByte, count: 20))

    try data.write(to: repoURL.appendingPathComponent(".git/index"))
}

func writeGitIndexVersion4(
    at repoURL: URL,
    trackedPath: String,
    signatureByte: UInt8
) throws {
    try writeGitIndexVersion4(at: repoURL, trackedPaths: [trackedPath], signatureByte: signatureByte)
}

func writeGitIndexVersion4(
    at repoURL: URL,
    trackedPaths: [String],
    signatureByte: UInt8
) throws {
    var data = Data()
    data.append(contentsOf: [0x44, 0x49, 0x52, 0x43])
    appendBigEndianUInt32(4, to: &data)
    appendBigEndianUInt32(UInt32(trackedPaths.count), to: &data)

    var previousPathBytes: [UInt8] = []
    for trackedPath in trackedPaths.sorted() {
        let fileURL = repoURL.appendingPathComponent(trackedPath)
        var statValue = stat()
        guard lstat(fileURL.path, &statValue) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }

        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_ctimespec.tv_sec), to: &data)
        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_ctimespec.tv_nsec), to: &data)
        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_mtimespec.tv_sec), to: &data)
        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_mtimespec.tv_nsec), to: &data)
        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_dev), to: &data)
        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_ino), to: &data)
        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_mode), to: &data)
        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_uid), to: &data)
        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_gid), to: &data)
        appendBigEndianUInt32(gitIndexUInt32Field(statValue.st_size), to: &data)
        data.append(Data(repeating: 0, count: 20))

        let pathBytes = Array(trackedPath.utf8)
        appendBigEndianUInt16(UInt16(min(pathBytes.count, 0x0fff)), to: &data)
        let commonPrefixLength = zip(previousPathBytes, pathBytes).prefix { pair in
            pair.0 == pair.1
        }.count
        let stripLength = previousPathBytes.count - commonPrefixLength
        data.append(contentsOf: gitIndexV4PathStripLengthBytes(stripLength))
        data.append(contentsOf: pathBytes.dropFirst(commonPrefixLength))
        data.append(0)
        previousPathBytes = pathBytes
    }

    data.append(Data(repeating: signatureByte, count: 20))

    try data.write(to: repoURL.appendingPathComponent(".git/index"))
}

func gitIndexV4PathStripLengthBytes(_ value: Int) -> [UInt8] {
    precondition(value >= 0)
    var remaining = value
    var bytes = [UInt8(remaining & 0x7f)]
    remaining >>= 7
    while remaining != 0 {
        remaining -= 1
        bytes.append(0x80 | UInt8(remaining & 0x7f))
        remaining >>= 7
    }
    return Array(bytes.reversed())
}

private func appendBigEndianUInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

private func appendBigEndianUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

private func gitIndexUInt32Field<T: BinaryInteger>(_ value: T) -> UInt32 {
    UInt32(truncatingIfNeeded: UInt64(truncatingIfNeeded: value))
}

