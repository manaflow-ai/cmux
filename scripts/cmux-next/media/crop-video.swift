// Cuts a box out of a video and scales it, as an H.264 MP4, with AVFoundation, which every Mac has.
// hot-verify.py's look uses it where there is no ffmpeg, which is every fleet display worker: the kit's
// Recorder (CuaDriver) records the whole main display, and the look keeps only the copy's window (another
// step's system dialogs show on the rest of the display), then shrinks a video too big to bring back.
//   crop-video IN OUT FX FY FW FH SCALE
// FX FY FW FH: the box as fractions of the video's width and height, from its top left corner. SCALE (0 to 1]:
// the output's size against the box's. Exit 0 with OUT written, else 1 with the reason on stderr.
import AVFoundation
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("crop-video: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 8 else { fail("usage: crop-video IN OUT FX FY FW FH SCALE") }
let numbers = arguments[3...7].map { Double($0) }
guard numbers.allSatisfy({ $0 != nil && $0!.isFinite }) else { fail("FX FY FW FH SCALE are numbers") }
let (fx, fy, fw, fh, scale) = (numbers[0]!, numbers[1]!, numbers[2]!, numbers[3]!, numbers[4]!)
guard fx >= 0, fy >= 0, fw > 0, fh > 0, fx + fw <= 1.001, fy + fh <= 1.001, scale > 0, scale <= 1 else {
    fail("the box \(fx) \(fy) \(fw) \(fh) is not inside the video, or the scale \(scale) is not in (0, 1]")
}

let source = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let asset = AVURLAsset(url: source)
guard let track = asset.tracks(withMediaType: .video).first else { fail("\(source.path) has no video track") }
let shown = track.naturalSize.applying(track.preferredTransform)
let (width, height) = (abs(shown.width), abs(shown.height))
guard width >= 2, height >= 2 else { fail("\(source.path) has no frame size") }

// Even pixel sizes and origins: H.264 wants even dimensions.
func even(_ value: Double) -> CGFloat { CGFloat(max(0, (value / 2).rounded(.down) * 2)) }
let x = even(fx * Double(width)), y = even(fy * Double(height))
let box = CGSize(width: min(even(fw * Double(width)), width - x), height: min(even(fh * Double(height)), height - y))
let render = CGSize(width: max(2, even(Double(box.width) * scale)), height: max(2, even(Double(box.height) * scale)))
let factor = render.width / box.width

// The render's coordinates start at the top left: move the box's corner there, then scale.
let place = CGAffineTransform(translationX: -x, y: -y).concatenating(CGAffineTransform(scaleX: factor, y: factor))
let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
layer.setTransform(track.preferredTransform.concatenating(place), at: .zero)
let instruction = AVMutableVideoCompositionInstruction()
instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
instruction.layerInstructions = [layer]
let composition = AVMutableVideoComposition()
composition.renderSize = render
let rate = track.nominalFrameRate > 0 ? track.nominalFrameRate : 30
composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(min(max(rate.rounded(), 1), 60)))
composition.instructions = [instruction]

// Highest quality at any scale: renderSize does the shrinking (the lower presets cap the size on their own).
let preset = AVAssetExportPresetHighestQuality
guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { fail("no export session for \(preset)") }
try? FileManager.default.removeItem(at: output)
export.outputURL = output
export.outputFileType = .mp4
export.shouldOptimizeForNetworkUse = true
export.videoComposition = composition
let done = DispatchSemaphore(value: 0)
export.exportAsynchronously { done.signal() }
if done.wait(timeout: .now() + 600) == .timedOut {
    export.cancelExport()
    fail("the export took over 600 s")
}
guard export.status == .completed else {
    fail("the export ended \(export.status.rawValue): \(export.error.map { "\($0)" } ?? "no error given")")
}
print("\(Int(render.width))x\(Int(render.height))")
