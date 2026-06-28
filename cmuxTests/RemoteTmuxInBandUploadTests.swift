import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("RemoteTmuxInBandUpload")
struct RemoteTmuxInBandUploadTests {
    @Test("sanitizedExtension accepts alphanumeric, rejects metacharacters")
    func sanitizeExtension() {
        #expect(RemoteTmuxInBandUpload.sanitizedExtension("png") == "png")
        #expect(RemoteTmuxInBandUpload.sanitizedExtension("JPEG2") == "JPEG2")
        #expect(RemoteTmuxInBandUpload.sanitizedExtension(nil) == nil)
        #expect(RemoteTmuxInBandUpload.sanitizedExtension("") == nil)
        #expect(RemoteTmuxInBandUpload.sanitizedExtension("p ng") == nil)
        #expect(RemoteTmuxInBandUpload.sanitizedExtension("png;rm") == nil)
        #expect(RemoteTmuxInBandUpload.sanitizedExtension("p\"g") == nil)
        #expect(RemoteTmuxInBandUpload.sanitizedExtension("p$g") == nil)
        #expect(RemoteTmuxInBandUpload.sanitizedExtension("../etc") == nil)
        #expect(RemoteTmuxInBandUpload.sanitizedExtension(String(repeating: "a", count: 17)) == nil)
    }

    @Test("base64Chunks splits the encoded string and reassembles exactly")
    func chunking() {
        let original = "the quick brown fox jumps over the lazy dog, repeatedly!! 0123456789"
        let base64 = Data(original.utf8).base64EncodedString()
        for size in [1, 2, 3, 7, base64.count - 1, base64.count, base64.count + 5] {
            let chunks = RemoteTmuxInBandUpload.base64Chunks(base64, size: size)
            #expect(chunks.joined() == base64)
            if size < base64.count {
                #expect(chunks.dropLast().allSatisfy { $0.count == size })
            }
        }
        #expect(RemoteTmuxInBandUpload.base64Chunks("", size: 4).isEmpty)
    }

    @Test("parseAck accepts OK with size+cksum, rejects everything else")
    func parseAck() {
        #expect(RemoteTmuxInBandUpload.parseAck(["OK:1024:3456789012"])
            == RemoteTmuxInBandUpload.Ack(size: 1024, cksum: 3_456_789_012))
        #expect(RemoteTmuxInBandUpload.parseAck(["OK:0:0"])
            == RemoteTmuxInBandUpload.Ack(size: 0, cksum: 0))
        #expect(RemoteTmuxInBandUpload.parseAck(["  OK:5:6  "])
            == RemoteTmuxInBandUpload.Ack(size: 5, cksum: 6))
        #expect(RemoteTmuxInBandUpload.parseAck(["ERR"]) == nil)
        #expect(RemoteTmuxInBandUpload.parseAck([""]) == nil)
        #expect(RemoteTmuxInBandUpload.parseAck(nil) == nil)
        #expect(RemoteTmuxInBandUpload.parseAck(["OK:5"]) == nil)
        #expect(RemoteTmuxInBandUpload.parseAck(["OK:abc:6"]) == nil)
        #expect(RemoteTmuxInBandUpload.parseAck(["OK:5:6:7"]) == nil)
    }

    @Test("posixCksum matches cksum(1) reference vectors")
    func cksum() {
        // Reference values from POSIX `cksum` (verified against /usr/bin/cksum).
        #expect(RemoteTmuxInBandUpload.posixCksum(Data()) == 4_294_967_295)
        #expect(RemoteTmuxInBandUpload.posixCksum(Data("a".utf8)) == 1_220_704_766)
        #expect(RemoteTmuxInBandUpload.posixCksum(Data("hello world".utf8)) == 1_135_714_720)
        #expect(RemoteTmuxInBandUpload.posixCksum(Data("The quick brown fox\n".utf8)) == 4_037_379_161)
    }

    @Test("command builders avoid tmux/shell-breaking characters")
    func commandSafety() {
        let id = RemoteTmuxInBandUpload.makeID(UUID())
        let chunk = Data("some binary-ish payload \u{1F600}".utf8).base64EncodedString()
        let commands = [
            RemoteTmuxInBandUpload.setupShellCommand(id: id),
            RemoteTmuxInBandUpload.appendShellCommand(id: id, chunk: chunk),
            RemoteTmuxInBandUpload.finalizeShellCommand(id: id, sanitizedExtension: "png"),
        ]
        for command in commands {
            // These would break the tmux double-quoted run-shell argument.
            #expect(!command.contains("\""))
            #expect(!command.contains("\\"))
            #expect(!command.contains("#"))
            #expect(!command.contains("\n"))
        }
        // id is hex only.
        #expect(id.allSatisfy { $0.isHexDigit })
    }

    @Test("makeID is hex without dashes; outputPath honors sanitized extension")
    func idsAndPaths() {
        let id = RemoteTmuxInBandUpload.makeID(UUID())
        #expect(!id.contains("-"))
        #expect(RemoteTmuxInBandUpload.outputPath(id: id, sanitizedExtension: "png")
            == "/tmp/cmux-drop-\(id).png")
        #expect(RemoteTmuxInBandUpload.outputPath(id: id, sanitizedExtension: nil)
            == "/tmp/cmux-drop-\(id)")
    }
}
