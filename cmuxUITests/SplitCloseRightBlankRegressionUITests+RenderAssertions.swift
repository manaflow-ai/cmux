import XCTest
import Foundation
import CoreGraphics
import ImageIO
import Darwin


// MARK: - Render assertions
extension SplitCloseRightBlankRegressionUITests {
    private struct CropStats {
        let sampleCount: Int
        let uniqueQuantized: Int
        let lumaStdDev: Double
        let modeFraction: Double
        let fingerprint: UInt64

        var isProbablyBlank: Bool {
            // Tuned for "terminal went visually blank": near-uniform region, very low contrast.
            // (The exact thresholds are conservative; we also require consecutive blank samples below.)
            return lumaStdDev < 2.5 && modeFraction > 0.992
        }
    }

    @discardableResult
    private func writeScreenshot(window: XCUIElement, name: String) -> String? {
        let shot = window.screenshot()
        let path = "\(screenshotDir)/\(name).png"
        do {
            try shot.pngRepresentation.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            return nil
        }
    }

    private func addKeptScreenshot(path: String, name: String) {
        let attachment = XCTAttachment(contentsOfFile: URL(fileURLWithPath: path))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func meanAbsLumaDiff(pngA: Data, pngB: Data, normalizedCrop: CGRect) -> Double? {
        guard let imageA = cgImage(from: pngA),
              let imageB = cgImage(from: pngB) else {
            return nil
        }
        guard imageA.width == imageB.width, imageA.height == imageB.height else { return nil }
        let width = imageA.width
        let height = imageA.height
        if width <= 0 || height <= 0 { return nil }

        let cropPx = CGRect(
            x: max(0, min(CGFloat(width - 1), normalizedCrop.origin.x * CGFloat(width))),
            y: max(0, min(CGFloat(height - 1), normalizedCrop.origin.y * CGFloat(height))),
            width: max(1, min(CGFloat(width), normalizedCrop.width * CGFloat(width))),
            height: max(1, min(CGFloat(height), normalizedCrop.height * CGFloat(height)))
        ).integral

        let x0 = Int(cropPx.minX)
        let y0 = Int(cropPx.minY)
        let x1 = Int(min(CGFloat(width), cropPx.maxX))
        let y1 = Int(min(CGFloat(height), cropPx.maxY))
        if x1 <= x0 || y1 <= y0 { return nil }

        guard let bufA = decodeRGBA(imageA), let bufB = decodeRGBA(imageB) else { return nil }
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        let step = 3
        var total = 0.0
        var count = 0
        for y in stride(from: y0, to: y1, by: step) {
            let row = y * bytesPerRow
            for x in stride(from: x0, to: x1, by: step) {
                let i = row + x * bytesPerPixel
                let ar = Double(bufA[i])
                let ag = Double(bufA[i + 1])
                let ab = Double(bufA[i + 2])
                let br = Double(bufB[i])
                let bg = Double(bufB[i + 1])
                let bb = Double(bufB[i + 2])
                let al = 0.2126 * ar + 0.7152 * ag + 0.0722 * ab
                let bl = 0.2126 * br + 0.7152 * bg + 0.0722 * bb
                total += abs(al - bl)
                count += 1
            }
        }
        return count > 0 ? (total / Double(count)) : nil
    }

    private func cgImage(from pngData: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func decodeRGBA(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var buf = [UInt8](repeating: 0, count: height * bytesPerRow)

        // Important: pass the *pixel buffer* pointer, not the Array object address.
        // Also pin the pixel format so our [r,g,b,a] indexing matches reality.
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }

            let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else { return false }

            // Note: do not flip the context here.
            // With CGImage decoded from XCUI screenshots, the bitmap memory we get from a plain
            // draw() already matches the "top-left origin" expectation used by our normalized crops.
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        return ok ? buf : nil
    }

    private func cropStats(pngData: Data, normalizedCrop: CGRect) -> CropStats? {
        guard let image = cgImage(from: pngData) else {
            return nil
        }

        let width = image.width
        let height = image.height
        if width <= 0 || height <= 0 { return nil }

        let cropPx = CGRect(
            x: max(0, min(CGFloat(width - 1), normalizedCrop.origin.x * CGFloat(width))),
            y: max(0, min(CGFloat(height - 1), normalizedCrop.origin.y * CGFloat(height))),
            width: max(1, min(CGFloat(width), normalizedCrop.width * CGFloat(width))),
            height: max(1, min(CGFloat(height), normalizedCrop.height * CGFloat(height)))
        ).integral

        // Render into a known RGBA8 buffer with top-left origin.
        guard let buf = decodeRGBA(image) else { return nil }
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        let x0 = Int(cropPx.minX)
        let y0 = Int(cropPx.minY)
        let x1 = Int(min(CGFloat(width), cropPx.maxX))
        let y1 = Int(min(CGFloat(height), cropPx.maxY))
        if x1 <= x0 || y1 <= y0 { return nil }

        // Sample every N pixels to keep this cheap and stable.
        let step = 3
        var lumas = [Double]()
        lumas.reserveCapacity(((x1 - x0) / step) * ((y1 - y0) / step))

        // Quantize RGB to 4 bits/channel and track uniqueness + mode.
        var hist = [UInt16: Int]()
        hist.reserveCapacity(256)

        var count = 0
        var fnv: UInt64 = 1469598103934665603 // FNV-1a offset basis
        for y in stride(from: y0, to: y1, by: step) {
            let rowBase = y * bytesPerRow
            for x in stride(from: x0, to: x1, by: step) {
                let i = rowBase + x * bytesPerPixel
                let r = Double(buf[i])
                let g = Double(buf[i + 1])
                let b = Double(buf[i + 2])
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                lumas.append(luma)

                let rq = UInt16(UInt8(buf[i]) >> 4)
                let gq = UInt16(UInt8(buf[i + 1]) >> 4)
                let bq = UInt16(UInt8(buf[i + 2]) >> 4)
                let key = (rq << 8) | (gq << 4) | bq
                hist[key, default: 0] += 1
                count += 1

                // Fingerprint based on quantized luma (coarse) plus position order.
                let lq = UInt8(max(0, min(63, Int(luma / 4.0)))) // ~6 bits
                fnv ^= UInt64(lq)
                fnv &*= 1099511628211
            }
        }

        guard count > 0 else { return nil }

        // stddev of luma
        let mean = lumas.reduce(0.0, +) / Double(lumas.count)
        let variance = lumas.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lumas.count)
        let stddev = sqrt(variance)

        // mode fraction
        let modeCount = hist.values.max() ?? 0
        let modeFrac = Double(modeCount) / Double(count)

        return CropStats(
            sampleCount: count,
            uniqueQuantized: hist.count,
            lumaStdDev: stddev,
            modeFraction: modeFrac,
            fingerprint: fnv
        )
    }

}
