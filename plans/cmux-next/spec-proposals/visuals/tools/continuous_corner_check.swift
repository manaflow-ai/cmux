// Checks the continuous-corner path in design-tokens.md against CALayer cornerCurve .continuous.
// usage: swift continuous_corner_check.swift [a b c d e f g]   (macOS 26; the seven constants default to the spec's)
// Prints, per chrome size: (max level difference, pixels off by more than 2) at 2x for
// circular vs continuous CALayer, the iOS 7 constants (mode0) and the spec path (mode3).
import AppKit
import QuartzCore

let scale: CGFloat = 2
let FIT: [CGFloat] = CommandLine.arguments.count > 7 ? CommandLine.arguments[1...7].map { CGFloat(Double($0)!) } : [1.547302, 1.084498, 0.882045, 0.644148, 0.070748, 0.376057, 0.163004]
func bitmap(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> [UInt8] {
    let cs = CGColorSpaceCreateDeviceGray()
    let pw = Int(CGFloat(w) * scale), ph = Int(CGFloat(h) * scale)
    let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
    ctx.scaleBy(x: scale, y: scale)
    draw(ctx)
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: p, count: pw * ph))
}
func layerBitmap(_ w: Int, _ h: Int, _ r: CGFloat, _ curve: CALayerCornerCurve) -> [UInt8] {
    bitmap(w, h) { ctx in
        let l = CALayer()
        l.frame = CGRect(x: 0, y: 0, width: w, height: h)
        l.backgroundColor = CGColor(gray: 1, alpha: 1)
        l.cornerRadius = r
        l.cornerCurve = curve
        l.contentsScale = scale
        l.render(in: ctx)
    }
}
// Reverse-engineered continuous corner: one corner = line, 3 cubics. k = edge extent multiplier.
func continuousPath(_ rect: CGRect, _ r0: CGFloat, mode: Int) -> CGPath {
    var r = r0
    let maxR = min(rect.width, rect.height) / 2
    let limit: CGFloat = 1.52866483
    var s: CGFloat = 1 // shrink factor on extents
    if mode == 1 { r = min(r, maxR / limit) }
    if mode == 2 { r = min(r, maxR); s = min(1, maxR / (limit * r)) }
    let p = CGMutablePath()
    let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
    func k(_ v: CGFloat) -> CGFloat { v * r * s }
    // control constants
    let K: [CGFloat] = mode == 3 ? FIT : [1.52866483, 1.08849323, 0.86840689, 0.66993427, 0.06549600, 0.37754822, 0.16550930]
    let (a, b, c, d, e, f, g) = (K[0], K[1], K[2], K[3], K[4], K[5], K[6])
    // corner function in local coords: start on top edge going right toward top-right corner
    func corner(_ t: (CGFloat, CGFloat) -> CGPoint) {
        p.addLine(to: t(k(a), 0))
        p.addCurve(to: t(k(d), k(e)), control1: t(k(b), 0), control2: t(k(c), 0))
        p.addCurve(to: t(k(e), k(d)), control1: t(k(f), k(g)), control2: t(k(g), k(f)))
        p.addCurve(to: t(0, k(a)), control1: t(0, k(c)), control2: t(0, k(b)))
    }
    p.move(to: CGPoint(x: minX + k(a), y: minY))
    corner { u, v in CGPoint(x: maxX - u, y: minY + v) }   // top-right (y down in math terms doesn't matter, symmetric)
    corner { u, v in CGPoint(x: maxX - v, y: maxY - u) }
    corner { u, v in CGPoint(x: minX + u, y: maxY - v) }
    corner { u, v in CGPoint(x: minX + v, y: minY + u) }
    p.closeSubpath()
    return p
}
func pathBitmap(_ w: Int, _ h: Int, _ r: CGFloat, mode: Int) -> [UInt8] {
    bitmap(w, h) { ctx in
        ctx.setShouldAntialias(true)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.addPath(continuousPath(CGRect(x: 0, y: 0, width: w, height: h), r, mode: mode))
        ctx.fillPath()
    }
}
func circBitmap(_ w: Int, _ h: Int, _ r: CGFloat) -> [UInt8] {
    bitmap(w, h) { ctx in
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()
    }
}
func cmp(_ a: [UInt8], _ b: [UInt8]) -> (Int, Int) {
    var mx = 0, n = 0
    for i in 0..<a.count { let d = abs(Int(a[i]) - Int(b[i])); mx = max(mx, d); if d > 2 { n += 1 } }
    return (mx, n)
}
let cases: [(Int, Int, CGFloat, String)] = [
    (120, 24, 6, "tab pill compact"), (150, 30, 7, "tab pill comfortable"), (24, 24, 6, "+ button compact"),
    (20, 20, 6, "trailing button compact"), (16, 16, 4, "close button compact"), (300, 24, 8, "omnibar compact r8"),
    (300, 28, 8, "omnibar comfortable r8"), (640, 400, 10, "palette compact"), (720, 480, 12, "palette comfortable"),
    (190, 24, 6, "sidebar row compact"), (190, 36, 6, "sidebar row subtitle"), (40, 12, 6, "pill r=h/2"), (60, 60, 30, "circle-ish"),
]
for (w, h, r, name) in cases {
    let ca = layerBitmap(w, h, r, .continuous)
    let circ = layerBitmap(w, h, r, .circular)
    var line = "\(name) \(w)x\(h) r\(r): CAcirc-vs-CGcirc \(cmp(circ, circBitmap(w, h, r)))  CAcont-vs-CAcirc \(cmp(ca, circ))"
    for m in [0, 3] { line += "  mode\(m) \(cmp(ca, pathBitmap(w, h, r, mode: m)))" }
    print(line)
}
