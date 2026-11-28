// Draws SF Symbols to PDFs (sf-out/NAME@WEIGHT.pdf), one page each, at one point size and three
// weights, so their relative sizes are Apple's own; scripts/icons/sf_pdf_paths.py reads the paths
// back out. Runs on a fleet Mac (never a person's Mac): swift export_sf_symbols.swift NAME...
import AppKit
let names = Array(CommandLine.arguments.dropFirst())
let out = "sf-out"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for name in names {
  guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { print("MISSING \(name)"); continue }
  for (wname, weight) in [("regular", NSFont.Weight.regular), ("medium", NSFont.Weight.medium), ("light", NSFont.Weight.light)] {
    let cfg = NSImage.SymbolConfiguration(pointSize: 100, weight: weight, scale: .medium)
    guard let img = base.withSymbolConfiguration(cfg) else { continue }
    var box = CGRect(origin: .zero, size: img.size)
    let data = NSMutableData()
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    img.draw(in: box)
    NSGraphicsContext.restoreGraphicsState()
    ctx.endPDFPage(); ctx.closePDF()
    data.write(toFile: "\(out)/\(name)@\(wname).pdf", atomically: true)
    print("SYM \(name) \(wname) size=\(img.size.width)x\(img.size.height)")
  }
}
