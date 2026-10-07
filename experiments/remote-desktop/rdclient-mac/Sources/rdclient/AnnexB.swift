import CoreMedia
import Foundation

/// H.264 Annex-B <-> length-prefixed (AVCC) conversion and format descriptions.
enum H264 {
    static let nalSPS: UInt8 = 7
    static let nalPPS: UInt8 = 8
    static let nalIDR: UInt8 = 5
    static let nalAUD: UInt8 = 9

    /// Splits an Annex-B byte range into NAL unit ranges (start codes removed).
    static func nalRanges(_ b: [UInt8], from start: Int) -> [Range<Int>] {
        var starts: [(code: Int, nal: Int)] = []
        var i = start
        let n = b.count
        while i + 3 <= n {
            if b[i] == 0, b[i + 1] == 0 {
                if b[i + 2] == 1 {
                    starts.append((i, i + 3)); i += 3; continue
                }
                if i + 4 <= n, b[i + 2] == 0, b[i + 3] == 1 {
                    starts.append((i, i + 4)); i += 4; continue
                }
            }
            i += 1
        }
        var out: [Range<Int>] = []
        for (k, s) in starts.enumerated() {
            var end = k + 1 < starts.count ? starts[k + 1].code : n
            // Trailing zero bytes belong to the next start code (zero_byte), not to this NAL.
            while end > s.nal, b[end - 1] == 0, k + 1 < starts.count { end -= 1 }
            if end > s.nal { out.append(s.nal..<end) }
        }
        return out
    }

    struct AccessUnit {
        var sps: [UInt8]?
        var pps: [UInt8]?
        /// AVCC payload: every non-parameter-set NAL with a 4-byte big-endian length.
        var avcc: [UInt8] = []
        var hasIDR = false
        var vclCount = 0
    }

    static func parse(_ b: [UInt8], from start: Int) -> AccessUnit {
        var au = AccessUnit()
        au.avcc.reserveCapacity(b.count - start + 16)
        for r in nalRanges(b, from: start) {
            let type = b[r.lowerBound] & 0x1f
            switch type {
            case nalSPS: au.sps = Array(b[r])
            case nalPPS: au.pps = Array(b[r])
            case nalAUD: continue
            default:
                if type == nalIDR { au.hasIDR = true }
                if type >= 1 && type <= 5 { au.vclCount += 1 }
                let len = UInt32(r.count)
                au.avcc.append(UInt8(len >> 24))
                au.avcc.append(UInt8((len >> 16) & 0xff))
                au.avcc.append(UInt8((len >> 8) & 0xff))
                au.avcc.append(UInt8(len & 0xff))
                au.avcc.append(contentsOf: b[r])
            }
        }
        return au
    }

    static func formatDescription(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        var fd: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                guard let sb = s.baseAddress, let pb = p.baseAddress else { return -1 }
                let ptrs: [UnsafePointer<UInt8>] = [sb, pb]
                let sizes: [Int] = [s.count, p.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            }
        }
        return status == noErr ? fd : nil
    }

    /// Wraps AVCC bytes in a CMSampleBuffer for VTDecompressionSession.
    static func sampleBuffer(avcc: [UInt8], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard st == noErr, let block else { return nil }
        st = avcc.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard st == noErr else { return nil }
        var sb: CMSampleBuffer?
        var size = avcc.count
        st = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
        return st == noErr ? sb : nil
    }

    /// Converts an encoder output sample (AVCC) to Annex-B, with SPS and PPS before keyframes,
    /// exactly as the host sends it on the wire.
    static func annexB(from sb: CMSampleBuffer, keyframe: Bool) -> [UInt8]? {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        var out: [UInt8] = []
        let startCode: [UInt8] = [0, 0, 0, 1]
        if keyframe, let fd = CMSampleBufferGetFormatDescription(sb) {
            for idx in 0..<2 {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fd, parameterSetIndex: idx, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                guard st == noErr, let ptr else { return nil }
                out += startCode
                out.append(contentsOf: UnsafeBufferPointer(start: ptr, count: size))
            }
        }
        let total = CMBlockBufferGetDataLength(block)
        var raw = [UInt8](repeating: 0, count: total)
        let st = raw.withUnsafeMutableBytes { dst -> OSStatus in
            guard let base = dst.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: base)
        }
        guard st == noErr else { return nil }
        var off = 0
        while off + 4 <= total {
            let len = Int(raw[off]) << 24 | Int(raw[off + 1]) << 16 | Int(raw[off + 2]) << 8 | Int(raw[off + 3])
            off += 4
            guard len > 0, off + len <= total else { return nil }
            out += startCode
            out.append(contentsOf: raw[off..<(off + len)])
            off += len
        }
        return out
    }
}
