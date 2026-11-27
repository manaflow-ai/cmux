// Prints each corpus entry's parse in cmux-chat-markdown's byte format (src/encode.rs), hex:
// "<document> <tail or ->" per line. A second argument N times N rounds instead.
import Foundation

struct W {
    var out: [UInt8] = []
    mutating func u8(_ v: UInt8) { out.append(v) }
    mutating func u32(_ v: Int) { let x = UInt32(clamping: v); for k in 0..<4 { out.append(UInt8((x >> (8 * UInt32(k))) & 0xFF)) } }
    mutating func i64(_ v: Int) { let x = UInt64(bitPattern: Int64(v)); for k in 0..<8 { out.append(UInt8((x >> (8 * UInt64(k))) & 0xFF)) } }
    mutating func str(_ s: String) { let b = Array(s.utf8); u32(b.count); out += b }
    mutating func blocks(_ bs: [MDBlock]) { u32(bs.count); for b in bs { block(b) } }
    mutating func text(_ t: MDText) {
        str(t.string); u32(t.spans.count)
        for s in t.spans {
            u32(s.location); u32(s.length)
            let st = s.style.rawValue; u8(UInt8(st & 0xFF)); u8(UInt8(st >> 8))
            u8((s.link != nil ? 1 : 0) | (s.image != nil ? 2 : 0))
            if let l = s.link { str(l) }
            if let i = s.image { str(i) }
        }
    }
    mutating func block(_ b: MDBlock) {
        let kind: UInt8
        switch b.kind {
        case .paragraph: kind = 0
        case .heading: kind = 1
        case .code: kind = 2
        case .quote: kind = 3
        case .list: kind = 4
        case .table: kind = 5
        case .rule: kind = 6
        }
        u8(kind); u8((b.rich ? 1 : 0) | (b.blankBefore ? 2 : 0))
        u32(b.lines.lowerBound); u32(b.lines.upperBound)
        switch b.kind {
        case .paragraph(let t): text(t)
        case .heading(let level, let t): u8(UInt8(level)); text(t)
        case .code(let lang, let t, let fenced, let closed): str(lang); str(t); u8((fenced ? 1 : 0) | (closed ? 2 : 0))
        case .quote(let bs): blocks(bs)
        case .list(let l):
            u8((l.ordered ? 1 : 0) | (l.loose ? 2 : 0)); i64(l.start); u32(l.items.count)
            for it in l.items { str(it.marker); u8(it.task == nil ? 0 : it.task == true ? 2 : 1); blocks(it.blocks) }
        case .table(let t):
            u32(t.aligns.count)
            for a in t.aligns { switch a { case .none: u8(0); case .left: u8(1); case .center: u8(2); case .right: u8(3) } }
            u32(t.header.count); for h in t.header { text(h) }
            u32(t.rows.count); for r in t.rows { u32(r.count); for c in r { text(c) } }
        case .rule: break
        }
    }
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

let path = CommandLine.arguments[1]
let data = try! Data(contentsOf: URL(fileURLWithPath: path))
let corpus = try! JSONDecoder().decode([String].self, from: data)
if CommandLine.arguments.count > 2, let rounds = Int(CommandLine.arguments[2]) {
    // Timing: every corpus text parsed `rounds` times, the best round's milliseconds.
    var best = Double.infinity
    var sink = 0
    for _ in 0..<rounds {
        let t0 = DispatchTime.now().uptimeNanoseconds
        for text in corpus { sink &+= Markdown.parse(text).blocks.count }
        best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }
    print("swift best round ms \(best) texts \(corpus.count) sink \(sink)")
    exit(0)
}
var lines: [String] = []
for text in corpus {
    let doc = Markdown.parse(text)
    var w = W(); w.u8(doc.isRich ? 1 : 0); w.blocks(doc.blocks)
    var tailHex = "-"
    if let last = doc.blocks.last, !last.lines.isEmpty {
        let ls = MDLines.split(text).map { MDLine($0) }
        let from = last.lines.lowerBound
        var refs = MDRefs()
        var tail = MDBlockParser.parse(Array(ls.slice(from: min(from, ls.count))), refs: &refs, known: nil, topLevel: true)
        tail = tail.map { var b = $0; b.lines = (b.lines.lowerBound + from)..<(b.lines.upperBound + from); return b }
        var tw = W(); tw.blocks(tail); tailHex = hex(tw.out)
    }
    lines.append(hex(w.out) + " " + tailHex)
}
print(lines.joined(separator: "\n"))
