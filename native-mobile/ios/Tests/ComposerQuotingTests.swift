import ImageIO
import UIKit
import Testing
@testable import CmuxNative

struct ComposerQuotingTests {
    @Test func plainPathStaysBare() {
        #expect(ComposerModel.shellQuoted("/Users/me/Library/Caches/cmux-native-host/uploads/2026-10-12/photo-1.jpg")
            == "/Users/me/Library/Caches/cmux-native-host/uploads/2026-10-12/photo-1.jpg")
    }

    @Test func spacesAndShellCharactersAreQuoted() {
        #expect(ComposerModel.shellQuoted("/tmp/IMG (1).jpg") == "'/tmp/IMG (1).jpg'")
        #expect(ComposerModel.shellQuoted("/tmp/a$b&c;d.txt") == "'/tmp/a$b&c;d.txt'")
        #expect(ComposerModel.shellQuoted("/tmp/日本.png") == "'/tmp/日本.png'")
    }

    @Test func embeddedSingleQuoteIsEscaped() {
        #expect(ComposerModel.shellQuoted("/tmp/Aziz's notes.pdf") == "'/tmp/Aziz'\\''s notes.pdf'")
    }

    @Test func emptyPathIsQuoted() {
        #expect(ComposerModel.shellQuoted("") == "''")
    }
}


struct PhotoLocationTests {
    private func jpegWithLocation() -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)!
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 122.03, kCGImagePropertyGPSLongitudeRef: "W"]
        CGImageDestinationAddImage(destination, image.cgImage!, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private func hasLocation(_ data: Data) -> Bool {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return properties[kCGImagePropertyGPSDictionary] != nil
    }

    @Test func locationIsRemoved() throws {
        let original = jpegWithLocation()
        #expect(hasLocation(original))
        let stripped = try #require(ComposerModel.strippingLocation(original))
        #expect(!hasLocation(stripped))
        #expect(UIImage(data: stripped) != nil)
    }

    @Test func photoWithoutLocationIsLeftAlone() {
        let plain = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).jpegData(withCompressionQuality: 0.9) { _ in }
        #expect(ComposerModel.strippingLocation(plain) == nil)
    }
}

struct ComposerPathJoinTests {
    @Test func attachmentsAloneAtAShellOnlyTypeThePaths() {
        #expect(ComposerModel.submits(text: "", hasPaths: true, isTUI: false) == false)
        #expect(ComposerModel.submits(text: " ", hasPaths: true, isTUI: false) == false)
        // An agent's prompt, typed text, or no attachments: Return as before.
        #expect(ComposerModel.submits(text: "", hasPaths: true, isTUI: true))
        #expect(ComposerModel.submits(text: "open", hasPaths: true, isTUI: false))
        #expect(ComposerModel.submits(text: "ls", hasPaths: false, isTUI: false))
    }

    @Test func oneSpaceBetweenTextAndPath() {
        #expect(ComposerModel.appendingPaths(["/tmp/a.jpg"], to: "file") == "file /tmp/a.jpg")
        #expect(ComposerModel.appendingPaths(["/tmp/a.jpg"], to: "file ") == "file /tmp/a.jpg")
        #expect(ComposerModel.appendingPaths(["/tmp/a.jpg", "/tmp/b c.png"], to: "") == "/tmp/a.jpg '/tmp/b c.png'")
    }
}
