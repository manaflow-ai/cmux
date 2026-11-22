import CoreVideo
import Foundation

/// The decoded value of the PROTOCOL.md marker: 16 data cells plus a 1,0,1,0 guard.
struct MarkerRead {
    let value: UInt16
    let guardOK: Bool
}

enum Marker {
    static let cell = 32
    static let dataCells = 16
    static let totalCells = 20
    static let guardBits = [true, false, true, false]

    static func isFullRange(_ pf: OSType) -> Bool {
        pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }
}

enum MarkerReader {
    /// Samples luma at each cell center; bit = Y > 128 (full range) or Y > 125 (video range).
    static func read(_ pb: CVPixelBuffer) -> MarkerRead? {
        let pf = CVPixelBufferGetPixelFormatType(pb)
        guard CVPixelBufferGetPlaneCount(pb) >= 1 else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pb, 0)
        let height = CVPixelBufferGetHeightOfPlane(pb, 0)
        guard width >= Marker.cell * Marker.totalCells, height >= Marker.cell else { return nil }
        let threshold: UInt8 = Marker.isFullRange(pf) ? 128 : 125
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let y = base.assumingMemoryBound(to: UInt8.self)
        let row = (Marker.cell / 2) * stride
        var bits = [Bool](repeating: false, count: Marker.totalCells)
        for i in 0..<Marker.totalCells {
            bits[i] = y[row + Marker.cell * i + Marker.cell / 2] > threshold
        }
        var v: UInt16 = 0
        for i in 0..<Marker.dataCells where bits[i] { v |= UInt16(1) << UInt16(i) }
        let guardOK = Array(bits[Marker.dataCells..<Marker.totalCells]) == Marker.guardBits
        return MarkerRead(value: v, guardOK: guardOK)
    }
}

enum MarkerWriter {
    /// Draws the marker for `counter` into the Y plane (UV neutral) of a locked bi-planar buffer.
    static func draw(counter: UInt16, y: UnsafeMutablePointer<UInt8>, yStride: Int,
                     uv: UnsafeMutablePointer<UInt8>, uvStride: Int, fullRange: Bool) {
        let white: UInt8 = fullRange ? 255 : 235
        let black: UInt8 = fullRange ? 0 : 16
        for i in 0..<Marker.totalCells {
            let on = i < Marker.dataCells ? (counter >> UInt16(i)) & 1 == 1 : Marker.guardBits[i - Marker.dataCells]
            let v = on ? white : black
            let x0 = i * Marker.cell
            for row in 0..<Marker.cell {
                (y + row * yStride + x0).update(repeating: v, count: Marker.cell)
            }
            for row in 0..<(Marker.cell / 2) {
                (uv + row * uvStride + x0).update(repeating: 128, count: Marker.cell)
            }
        }
    }
}
