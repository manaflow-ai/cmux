import Bonsplit
import CmuxControlSocket
import CoreGraphics
import Foundation
import ImageIO
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Surface icon SVG validation and rasterization")
struct SurfaceIconSVGRendererTests {
    private let valid = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 28 28\"><path d=\"M2 2 L26 2 L14 26 Z\" fill=\"#12abEF\"/></svg>"

    @Test func rasterizesPNGAndHashesAllPlaybackFields() async throws {
        let svg = valid
        let result = try await Task.detached {
            let renderer = SurfaceIconSVGRenderer()
            let first = try renderer.render(ControlSurfaceIconAsset(
                frames: [.init(svg: svg, durationMS: 100), .init(svg: svg, durationMS: 200)], loop: true))
            let duplicate = try renderer.render(ControlSurfaceIconAsset(
                frames: [.init(svg: svg, durationMS: 100), .init(svg: svg, durationMS: 200)], loop: true))
            let timing = try renderer.render(ControlSurfaceIconAsset(
                frames: [.init(svg: svg, durationMS: 150), .init(svg: svg, durationMS: 200)], loop: true))
            let loop = try renderer.render(ControlSurfaceIconAsset(
                frames: [.init(svg: svg, durationMS: 100), .init(svg: svg, durationMS: 200)], loop: false))
            let fallback = try renderer.render(ControlSurfaceIconAsset(
                frames: [.init(svg: svg, durationMS: 100), .init(svg: svg, durationMS: 200)], loop: true, staticFrame: 1))
            return (first, duplicate, timing, loop, fallback)
        }.value
        #expect(result.0 == result.1)
        #expect(Set([result.0.id, result.2.id, result.3.id, result.4.id]).count == 4)
        #expect(result.0.durations == [0.1, 0.2])
        #expect(result.0.loops)
        #expect(result.4.staticFrameIndex == 1)
        for png in result.0.frames {
            #expect(Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 64)
            #expect(image.height == 64)
            let provider = try #require(image.dataProvider?.data)
            let bytes = try #require(CFDataGetBytePtr(provider))
            #expect((0..<CFDataGetLength(provider)).contains { bytes[$0] != 0 })
        }
    }

    @Test func renderedContentChangesIdentity() async throws {
        let svg = valid
        let result = try await Task.detached {
            let renderer = SurfaceIconSVGRenderer()
            let original = try renderer.render(ControlSurfaceIconAsset(
                frames: [.init(svg: svg, durationMS: 100)], loop: false))
            let recolored = try renderer.render(ControlSurfaceIconAsset(
                frames: [.init(svg: svg.replacingOccurrences(of: "#12abEF", with: "#ff0000"), durationMS: 100)], loop: false))
            return (original, recolored)
        }.value
        #expect(result.0.id != result.1.id)
        #expect(result.0.frames != result.1.frames)
    }

    @MainActor @Test func rejectsMainThreadRasterization() {
        #expect(throws: SurfaceIconSVGRenderer.RenderError.requiresBackgroundThread) {
            try SurfaceIconSVGRenderer().render(ControlSurfaceIconAsset(
                frames: [.init(svg: valid, durationMS: 100)], loop: false))
        }
    }

    @Test func invalidAssetBudgetsAreRejected() async throws {
        let svg = valid
        try await Task.detached {
            let renderer = SurfaceIconSVGRenderer()
            let validFrame = ControlSurfaceIconFrame(svg: svg, durationMS: 100)
            let invalid = [
                ControlSurfaceIconAsset(frames: [], loop: false),
                ControlSurfaceIconAsset(frames: Array(repeating: validFrame, count: 65), loop: false),
                ControlSurfaceIconAsset(frames: [validFrame], loop: false, staticFrame: -1),
                ControlSurfaceIconAsset(frames: [validFrame], loop: false, staticFrame: 1),
                ControlSurfaceIconAsset(frames: [.init(svg: svg, durationMS: 49)], loop: false),
                ControlSurfaceIconAsset(frames: [.init(svg: svg, durationMS: 5001)], loop: false),
                ControlSurfaceIconAsset(frames: Array(repeating: .init(svg: svg, durationMS: 5000), count: 7), loop: false),
                ControlSurfaceIconAsset(frames: Array(repeating: .init(svg: String(repeating: " ", count: 16 * 1024), durationMS: 100), count: 33), loop: false)
            ]
            for asset in invalid {
                #expect(throws: SurfaceIconSVGRenderer.RenderError.invalidAsset) { try renderer.render(asset) }
            }
        }.value
    }

    @Test(arguments: [
        "<image href=\"https://example.com/a.png\"/>", "<use href=\"file:///etc/passwd\"/>",
        "<script/>", "<foreignObject/>", "<style/>", "<text>hello</text>",
        "<path d=\"M0 0L1 1\" fill=\"url(https://example.com)\"/>",
        "<path d=\"M0 0L1 1\" fill=\"currentColor\"/>",
        "<path d=\"M0 0L1 1\" fill=\"red\"/>",
        "<path d=\"M0 0L1 1\" style=\"fill:#fff\"/>",
        "<path d=\"M0 0L1 1\" onclick=\"alert(1)\"/>",
        "<path d=\"M0 0 L1e999 1\"/>", "<path d=\"M0 0 L10001 1\"/>",
        "<path d=\"M0 0 LNaN 1\"/>", "<path d=\"M0 0 X1 1\"/>",
        "<path d=\"L1 1\"/>", "<path d=\"M0 0 L1\"/>",
        "<path d=\"M0 0 A1 1 0 2 0 2 2\"/>",
        "<g transform=\"matrix(1 0 0 1 0 0)\"/>",
        "<g transform=\"translate(129)\"/>", "<g transform=\"scale(11)\"/>",
        "<g transform=\"rotate(3601)\"/>", "<g transform=\"translate(1)garbage\"/>",
        "<g transform=\"scale(10) scale(10)\"/>",
        "<g transform=\"scale(2)\"><g transform=\"scale(2)\"/></g>",
        "<circle r=\"-1\"/>", "<rect width=\"10%\"/>", "<g opacity=\"2\"/>",
        "<svg viewBox=\"0 0 28 28\"/>", "<g>&amp;</g>", "<!-- comment -->", "<?processing x?>"
    ])
    func rejectsUnsafeOrMalformedElements(_ element: String) {
        let source = "<svg viewBox=\"0 0 28 28\">\(element)</svg>"
        #expect(throws: SurfaceIconSVGValidator.ValidationError.invalidSVG) {
            try SurfaceIconSVGValidator().validate(source)
        }
    }

    @Test(arguments: [
        "", "<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><svg viewBox='0 0 28 28'>&x;</svg>",
        "<?xml version='1.0'?><svg viewBox='0 0 28 28'/>",
        "<svg viewBox='0 0 0 28'/>", "<svg viewBox='-1 0 28 28'/>",
        "<svg viewBox='0 0 10000 28'/>", "<svg width='10000' viewBox='0 0 28 28'/>",
        "<svg viewBox='0 0 1e-99 28'/>", "<svg width='1e-99' viewBox='0 0 28 28'/>",
        "<svg/>", "<svg viewBox='0 0 28 28'>not whitespace</svg>",
        "<svg viewBox='0 0 28 28'/><svg viewBox='0 0 28 28'/>"
    ])
    func rejectsUnsafeDocuments(_ source: String) {
        #expect(throws: SurfaceIconSVGValidator.ValidationError.invalidSVG) {
            try SurfaceIconSVGValidator().validate(source)
        }
    }

    @Test func boundsDocumentComplexity() {
        let validator = SurfaceIconSVGValidator()
        for source in [
            "<svg viewBox='0 0 28 28'>" + String(repeating: "<g/>", count: 256) + "</svg>",
            "<svg viewBox='0 0 28 28'>" + String(repeating: "<g>", count: 32) + String(repeating: "</g>", count: 32) + "</svg>",
            "<svg viewBox='0 0 28 28'><path d='M0 0 " + String(repeating: "L1 1 ", count: 1100) + "'/></svg>",
            String(repeating: " ", count: 16 * 1024 + 1)
        ] {
            #expect(throws: SurfaceIconSVGValidator.ValidationError.invalidSVG) { try validator.validate(source) }
        }
    }

    @Test func permitsBoundedGeometryAndTransforms() throws {
        try SurfaceIconSVGValidator().validate("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 28 28" width="28" height="28">
          <g transform="translate(1,-2) rotate(45 14 14) scale(.5)" opacity=".5">
            <rect x="1" y="2" width="3" height="4" rx="1" fill="#fff"/>
            <circle cx="14" cy="14" r="5" fill="none" stroke="#123456" stroke-width="2"/>
            <path d="M1 1 l2-1 H4 V5 C1 2 3 4 5 6 S1 2 3 4 Q1 2 3 4 T5 6 A2 2 0 0 1 8 8 z"
                  stroke-linecap="round" stroke-linejoin="bevel" fill-opacity="1" stroke-opacity="0"/>
          </g>
        </svg>
        """)
    }
}
