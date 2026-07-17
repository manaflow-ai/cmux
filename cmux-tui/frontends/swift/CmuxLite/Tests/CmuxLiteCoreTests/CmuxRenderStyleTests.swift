@testable import CmuxLiteCore
import Testing

@Suite
struct CmuxRenderStyleTests {
    @Test
    func mapsEveryProtocolAttributeBit() {
        let attributes = CmuxRenderAttributes(rawValue: 0x007F)
        let style = attributes.style(underline: .dashed)

        #expect(style.bold)
        #expect(style.italic)
        #expect(style.strikethrough)
        #expect(style.inverse)
        #expect(style.dim)
        #expect(style.invisible)
        #expect(style.blink)
        #expect(style.underline == .dashed)
    }

    @Test(arguments: [
        CmuxRenderUnderline.single,
        .double,
        .curly,
        .dotted,
        .dashed,
    ])
    func preservesEveryUnderlineVariant(_ underline: CmuxRenderUnderline) {
        #expect(CmuxRenderAttributes().style(underline: underline).underline == underline)
    }

    @Test
    func ignoresReservedBitsWhenResolvingKnownStyles() {
        let style = CmuxRenderAttributes(rawValue: 0xFF80).style(underline: nil)
        #expect(style == CmuxRenderStyle(
            bold: false,
            italic: false,
            strikethrough: false,
            inverse: false,
            dim: false,
            invisible: false,
            blink: false,
            underline: nil
        ))
    }
}
