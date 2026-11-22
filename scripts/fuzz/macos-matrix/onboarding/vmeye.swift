// vmeye: the onboarding suite's eyes on the VM host. It reads text off a VNC frame and turns the
// run's frames into a video. It runs on the Tart host only, compiled by vm.sh like a probe; it
// never runs in the guest, so the guest gets no grant and no tool that a person would not have.
//
//   vmeye ocr FRAME.png            one JSON line per text line: {"text", "x", "y", "w", "h", "conf"}
//                                  in the frame's pixels, top-left origin (Vision, accurate level)
//   vmeye video FRAMES.txt OUT.mp4 FRAMES.txt holds "SECONDS PATH" lines (seconds since the run
//                                  started); each frame is shown until the next one, H.264 at 10 fps
import AVFoundation
import AppKit
import Foundation
import Vision

func loadImage(_ path: String) -> CGImage? {
    guard let data = FileManager.default.contents(atPath: path),
          let rep = NSBitmapImageRep(data: data) else { return nil }
    return rep.cgImage
}

func ocr(_ path: String) -> Int32 {
    guard let image = loadImage(path) else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
        return 2
    }
    let width = CGFloat(image.width), height = CGFloat(image.height)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    do {
        try VNImageRequestHandler(cgImage: image).perform([request])
    } catch {
        FileHandle.standardError.write(Data("vision: \(error)\n".utf8))
        return 2
    }
    for observation in request.results ?? [] {
        guard let best = observation.topCandidates(1).first else { continue }
        let box = observation.boundingBox  // normalized, bottom-left origin
        let row: [String: Any] = [
            "text": best.string,
            "x": Int(box.minX * width), "y": Int((1 - box.maxY) * height),
            "w": Int(box.width * width), "h": Int(box.height * height),
            "conf": Double(best.confidence),
        ]
        if let json = try? JSONSerialization.data(withJSONObject: row),
           let line = String(data: json, encoding: .utf8) {
            print(line)
        }
    }
    return 0
}

func video(_ list: String, _ out: String) -> Int32 {
    guard let text = try? String(contentsOfFile: list, encoding: .utf8) else { return 2 }
    let frames: [(Double, String)] = text.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let at = Double(parts[0]) else { return nil }
        return (at, String(parts[1]))
    }
    guard let first = frames.first, let firstImage = loadImage(first.1) else { return 2 }
    // Half size keeps the file small; text in the stills stays full size.
    let width = firstImage.width / 2 / 2 * 2, height = firstImage.height / 2 / 2 * 2
    try? FileManager.default.removeItem(atPath: out)
    guard let writer = try? AVAssetWriter(outputURL: URL(fileURLWithPath: out), fileType: .mp4) else { return 2 }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let fps = 10.0
    let end = (frames.last?.0 ?? 0) + 1
    var index = 0, tick = 0
    var current: CGImage? = firstImage
    while Double(tick) / fps < end {
        let at = Double(tick) / fps
        while index + 1 < frames.count, frames[index + 1].0 <= at {
            index += 1
            current = loadImage(frames[index].1) ?? current
        }
        while !input.isReadyForMoreMediaData { usleep(1000) }
        guard let pool = adaptor.pixelBufferPool, let image = current else { break }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pixels = buffer else { break }
        CVPixelBufferLockBaseAddress(pixels, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) {
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(tick), timescale: CMTimeScale(fps)))
        tick += 1
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    return writer.status == .completed ? 0 : 1
}

let args = CommandLine.arguments
switch (args.count > 1 ? args[1] : "", args.count) {
case ("ocr", 3): exit(ocr(args[2]))
case ("video", 4): exit(video(args[2], args[3]))
default:
    FileHandle.standardError.write(Data("usage: vmeye ocr FRAME.png | vmeye video FRAMES.txt OUT.mp4\n".utf8))
    exit(2)
}
