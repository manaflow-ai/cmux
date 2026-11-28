import CoreGraphics
import Foundation
import ImageIO

struct Counts: Encodable {
    let red: Int
    let green: Int
    let blue: Int
    let yellow: Int
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: verify-colors.swift <screenshot.png>\n", stderr)
    exit(2)
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard
    let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    fputs("failed to load image: \(url.path)\n", stderr)
    exit(2)
}

let width = image.width
let height = image.height
let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel
var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGBitmapInfo(rawValue:
    CGImageAlphaInfo.premultipliedLast.rawValue |
    CGBitmapInfo.byteOrder32Big.rawValue
)

guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: colorSpace,
    bitmapInfo: bitmapInfo.rawValue
) else {
    fputs("failed to create bitmap context\n", stderr)
    exit(2)
}

context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

var red = 0
var green = 0
var blue = 0
var yellow = 0

for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
    let r = Int(pixels[offset])
    let g = Int(pixels[offset + 1])
    let b = Int(pixels[offset + 2])

    if r > 140 && g < 110 && b < 110 {
        red += 1
    }
    if g > 120 && r < 120 && b < 120 {
        green += 1
    }
    if b > 140 && r < 130 && g < 170 {
        blue += 1
    }
    if r > 140 && g > 110 && b < 120 {
        yellow += 1
    }
}

let counts = Counts(red: red, green: green, blue: blue, yellow: yellow)
let data = try JSONEncoder().encode(counts)
let output = String(data: data, encoding: .utf8) ?? "{}"
print(output)

let minimum = ProcessInfo.processInfo.environment["COLOR_MIN_PIXELS"].flatMap(Int.init) ?? 2_000
if red < minimum || green < minimum || blue < minimum || yellow < minimum {
    fputs("color verification failed: \(output)\n", stderr)
    exit(1)
}
