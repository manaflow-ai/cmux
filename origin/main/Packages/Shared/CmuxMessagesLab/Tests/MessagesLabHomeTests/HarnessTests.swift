import AppKit
import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The Home path against MessagesLab's: the same conversation driven once
/// with the actions MessagesLab's engine dispatches (send, external insert,
/// delivered, read, typing, receive, tapback) and once through the adapter
/// (HomeStore-shaped snapshots -> `ProjectionCore` -> actions). The
/// committed animations (`animations.ndjson`, key paths, begin times,
/// springs and curves) and the presented layer tree of every 120 Hz tick
/// must be identical. `HOME_HARNESS_OUT=DIR` keeps both runs.
@MainActor @Suite(.serialized) struct HomeHarnessTests {
    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")
    static let id = ConversationID("conv_harness")
    static let end = 9.2
    static let transitions: [(t: Double, name: String)] = [
        (0.50, "send (2 lines, morph)"), (1.60, "delivered"), (2.60, "delivered -> read"), (3.20, "typing indicator"),
        (4.40, "received message"), (5.60, "external insert (mine, from the CLI)"), (6.80, "tapback"), (7.20, "received message 2"),
        (8.20, "send (1 line, morph)"),
    ]
    static let draft = "How are you doing?\nSome multiline text..."
    /// A 1-line draft: its send morph uses bubble.width.oneLine and bubble.right.oneLine (MessagesLab dbc3106).
    static let oneLine = "Sounds good."

    static func date(_ t: Double) -> Date { Replay.base.addingTimeInterval(t) }

    static var people: [CmuxHomeCore.Participant] {
        [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
         CmuxHomeCore.Participant(id: them, kind: .agent, displayName: "Instinct", agentClass: .chief)]
    }

    static func summary(lastSeq: Seq, read: (Seq, Double)? = nil) -> ConversationSummary {
        var cursors: [ParticipantID: Seq] = [:]
        var times: [ParticipantID: Date] = [:]
        if let read {
            cursors[them] = read.0
            times[them] = date(read.1)
        }
        return ConversationSummary(id: id, title: "Instinct", participants: people, lastSeq: lastSeq, createdAt: date(-9000),
                                   updatedAt: date(0), readCursors: cursors, readCursorTimes: times)
    }

    static func item(_ seq: Seq, _ author: ParticipantID, _ text: String, at t: Double, key: String? = nil) -> TranscriptItem {
        TranscriptItem(key: IdempotencyKey(key ?? "h\(seq)"), seq: seq, author: author, parts: [.text(text)], createdAt: date(t),
                       delivery: .committed, messageID: MessageID("msg_\(seq)"))
    }

    static var base: [TranscriptItem] {
        var out: [TranscriptItem] = []
        for i in 1...30 {
            let author: ParticipantID = i % 3 == 0 ? me : them
            let text: String = i % 4 == 0 ? "A longer message number \(i) that wraps onto a second line in the bubble." : "Message \(i)"
            let at: Double = -Double(31 - i) * 50
            out.append(item(Seq(i), author, text, at: at))
        }
        return out
    }

    /// A catalyst message as MessagesLab's own script writes it.
    static func lab(_ id: String, _ sender: ParticipantID, _ text: String, at t: Double, status: DeliveryStatus? = nil) -> MessagesLabHome.Message {
        MessagesLabHome.Message(id: id, senderId: sender.rawValue, sentAt: Instant.format(date(t)), parts: [.text(text, runs: [])],
                                replyTo: nil, status: status, edits: nil, retractedAt: nil, reactions: [])
    }

    struct Run { var animations: [String]; var frames: [String] }

    /// One offscreen window view on a virtual clock (the loop of MessagesLab's DiffHarness.runOffscreen).
    static func run(_ store: Store, _ events: [(Double, (Store) -> Void)]) -> Run {
        DisplayScale.current = 2
        Fixture.renderScale = 2
        // Each run starts as a fresh process would (DiffHarness runs one per
        // process): the first rows are configured before `captureMode` turns
        // synchronous bitmaps on, and the bitmap cache is cold.
        RowCell.synchronousBitmaps = false
        RowBitmaps.shared.removeAll()
        MeasureCache.shared.trim(keeping: [])
        for (t, e) in events { store.scheduleStep(at: t, e) }
        var vt = 0.0
        let view = MessagesWindowView(store: store)
        view.clock = { vt }
        view.captureMode = true
        view.layer.isGeometryFlipped = true
        view.layer.speed = 0
        var run = Run(animations: [], frames: [])
        for k in 0...Int(end * 120) {
            let t = Double(k) / 120
            vt = t
            view.layer.timeOffset = t
            store.advance(to: t)
            view.prepareCapture(at: t)
            view.layoutIfNeeded()
            view.collection.layoutIfNeeded()
            view.layer.displayRecursively()
            if transitions.contains(where: { Int(($0.t * 120).rounded()) + 2 == k }) {
                run.animations.append(LayerDump.animations(t, view))
            }
            let saved = Presenter.apply(view.layer)
            run.frames.append(LayerDump.frame(t, view))
            Presenter.restore(saved)
        }
        return run
    }

    /// MessagesLab's engine: the actions its store dispatches for these events.
    static func messagesLab() -> Run {
        var core = ProjectionCore(me: me)
        let (conv, w) = core.install(id, items: base, summary: summary(lastSeq: 30))
        let store = Store(conversation: conv, baseDate: Replay.base, windowStart: w.start, total: w.total)
        store.responder = nil
        var sent: ID = ""
        return run(store, [
            (0.10, { $0.dispatch(.setDraft(draft)) }),
            (0.50, { s in s.dispatch(.send); sent = s.state.conversation.messages.last!.id }),
            (1.60, { $0.dispatch(.status(sent, .delivered(at: Instant.format(date(0.5))))) }),
            (2.60, { $0.dispatch(.status(sent, .read(at: Instant.format(date(2.6))))) }),
            (3.20, { $0.dispatch(.typing(them.rawValue, true)) }),
            (4.40, { $0.dispatch(.receive(lab("h32", them, "Doing well, and the multiline renders nicely.", at: 4.4))) }),
            (5.60, { $0.dispatch(.receive(lab("ext", me, "Sent from the cmux CLI", at: 5.6, status: .delivered(at: Instant.format(date(5.6)))))) }),
            (6.80, { $0.dispatch(.react(PartRef(messageId: sent, partIndex: 0), .tapback("love"), by: them.rawValue)) }),
            (7.20, { $0.dispatch(.receive(lab("h34", them, "Got both.", at: 7.2))) }),
            (7.80, { $0.dispatch(.setDraft(oneLine)) }),
            (8.20, { $0.dispatch(.send) }),
        ])
    }

    /// The Home path: HomeStore snapshots through the adapter's core.
    static func home() -> Run {
        var core = ProjectionCore(me: me)
        let (conv, w) = core.install(id, items: base, summary: summary(lastSeq: 30))
        let store = Store(conversation: conv, baseDate: Replay.base, windowStart: w.start, total: w.total)
        store.responder = nil
        var items = base
        var sum = summary(lastSeq: 30)
        var typing: Set<ParticipantID> = []
        let key = IdempotencyKey("cmk_harness_send")
        let key2 = IdempotencyKey("cmk_harness_send_one_line")
        func push(_ s: Store) {
            let d = core.step(items: items, summary: sum)
            precondition(!d.rebuild, "the script never rebuilds")
            d.actions.forEach(s.dispatch)
            core.typing(s.state, wanted: typing).forEach(s.dispatch)
        }
        var mine = TranscriptItem(key: key, seq: nil, author: me, parts: [.text(draft)], createdAt: date(0.5), delivery: .sending)
        return run(store, [
            (0.10, { $0.dispatch(.setDraft(draft)) }),
            // HomeProjection.send: `.send` at the press, then the alias.
            (0.50, { s in s.dispatch(.send); _ = core.recordSend(key, in: s.state) }),
            (0.501, { s in items.append(mine); push(s) }),
            (1.60, { s in mine.seq = 31; mine.delivery = .committed; mine.messageID = MessageID("msg_31"); items[items.count - 1] = mine
                sum = summary(lastSeq: 31); push(s) }),
            (2.60, { s in sum = summary(lastSeq: 31, read: (31, 2.6)); push(s) }),
            (3.20, { s in typing = [them]; push(s) }),
            (4.40, { s in typing = []; items.append(item(32, them, "Doing well, and the multiline renders nicely.", at: 4.4)); push(s) }),
            (5.60, { s in items.append(item(33, me, "Sent from the cmux CLI", at: 5.6, key: "ext")); push(s) }),
            (6.80, { s in mine.reactions = [CmuxHomeCore.Reaction(author: them, partIndex: 0, kind: .tapback(.love))]
                items[30] = mine; push(s) }),
            (7.20, { s in items.append(item(34, them, "Got both.", at: 7.2)); push(s) }),
            (7.80, { $0.dispatch(.setDraft(oneLine)) }),
            // HomeProjection.send again: `.send` at the press, the alias, then HomeStore's pending item.
            (8.20, { s in s.dispatch(.send); _ = core.recordSend(key2, in: s.state) }),
            (8.201, { s in items.append(TranscriptItem(key: key2, seq: nil, author: me, parts: [.text(oneLine)], createdAt: date(8.2),
                                                         delivery: .sending)); push(s) }),
        ])
    }

    /// Two frames.ndjson lines: equal values for every layer visible in either.
    static func sameVisible(_ x: String, _ y: String) -> Bool {
        if x == y { return true }
        func layers(_ s: String) -> [String: [Double]] {
            let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
            return (o?["L"] as? [String: [Double]]) ?? [:]
        }
        let a = layers(x), b = layers(y)
        let hidden = LayerDump.hidden, opacity = LayerDump.opacity
        func shows(_ v: [Double]?) -> Bool { v.map { $0[hidden] == 0 && $0[opacity] > 0.011 } ?? false }
        for name in Set(a.keys).union(b.keys) {
            let va = a[name], vb = b[name]
            if let va, let vb, va[hidden] == 1, vb[hidden] == 1 { continue }
            if va == nil || vb == nil { if shows(va) || shows(vb) { return false } else { continue } }
            if va! != vb! { return false }
        }
        return true
    }

    @Test func theHomePathCommitsMessagesLabsAnimationsByteForByte() throws {
        let a = Self.messagesLab()
        let b = Self.home()
        if let dir = ProcessInfo.processInfo.environment["HOME_HARNESS_OUT"] {
            for (name, r) in [("messageslab", a), ("home", b)] {
                let d = dir + "/" + name
                try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
                try r.animations.joined(separator: "\n").write(toFile: d + "/animations.ndjson", atomically: true, encoding: .utf8)
                try r.frames.joined(separator: "\n").write(toFile: d + "/frames.ndjson", atomically: true, encoding: .utf8)
            }
        }
        #expect(a.animations.count == Self.transitions.count)
        for (i, tr) in Self.transitions.enumerated() {
            #expect(a.animations[i] == b.animations[i], "animations differ at \(tr.name)")
            #expect(a.animations[i].contains("\"layers\":{\""), "\(tr.name) committed animations")
        }
        // diff.py's rule: a layer hidden in both runs carries no pixels (a
        // pooled cell's leftover geometry follows the recycler's pool order).
        let differing = zip(a.frames, b.frames).enumerated().filter { !Self.sameVisible($0.element.0, $0.element.1) }.map(\.offset)
        #expect(differing.isEmpty, "presented layer trees differ at ticks \(differing.prefix(10))")
    }

    /// The Home path's motion against a recorded golden (Golden/home-motion.ndjson), one line per
    /// entry of `motionTransitions`, in that order:
    /// 1. delivered and 2. delivered -> read: the committed animations from 1.6 s and 2.6 s
    ///    (MessagesLab's motion-gate rows row[receipt:...]);
    /// 3. typing indicator: its committed animations from 3.2 s (row[typing]) plus a window of the
    ///    presented row[typing] layers over 0.50-2.70 s of `typingOnly` (its breathing, 7cdd49b);
    /// 4. send (1 line, morph): the 1-line send's morph from 8.2 s (bubble.width.oneLine and
    ///    bubble.right.oneLine; MessagesLab's local-2/local-3 rows);
    /// 5. send (2 lines, morph): the multi-line send's morph from 0.5 s (bubble.width.fieldShrink).
    /// The test above compares Home with MessagesLab on the same vendored code, so a new pin that
    /// changes this motion keeps it green; this one fails until the golden is recorded again on
    /// purpose (HOME_HARNESS_WRITE_GOLDEN=1, named in the pin's commit). Recorded with the harness
    /// host's OS (scripts/cmux-next/home-messageslab-harness.sh).
    static let motionTransitions = ["delivered", "delivered -> read", "typing indicator", "send (1 line, morph)",
                                    // MessagesLab 60fbe32: the multi-line (field-shrink) send's morph, bubble.width.fieldShrink.
                                    "send (2 lines, morph)"]

    /// The indicator shows at 0.50 s in `typingOnly` and stays: ticks 0.50 s to 2.70 s (2.2 s, more than
    /// the bubble's 1.906 s breathing period and both discs' periods), every 2nd: only row[typing] layers.
    static let typingWindowTicks = stride(from: Int((0.50 * 120).rounded()), through: Int((2.70 * 120).rounded()), by: 2)

    /// The Home path with the base conversation and the Chief typing from 0.50 s on (no reply).
    static func typingOnly() -> Run {
        var core = ProjectionCore(me: me)
        let (conv, w) = core.install(id, items: base, summary: summary(lastSeq: 30))
        let store = Store(conversation: conv, baseDate: Replay.base, windowStart: w.start, total: w.total)
        store.responder = nil
        return run(store, [(0.50, { s in core.typing(s.state, wanted: [them]).forEach(s.dispatch) })])
    }

    static func typingWindow(_ frames: [String]) -> [String] {
        typingWindowTicks.compactMap { k -> String? in
            guard let line = frames[checked: k],
                  let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let layers = o["L"] as? [String: Any] else { return nil }
            let typing = layers.filter { $0.key.hasPrefix("row[typing]") }
            let obj: [String: Any] = ["t": o["t"] ?? 0, "L": typing]
            guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
            return String(data: d, encoding: .utf8)
        }
    }

    /// cmux-classic: the golden is recorded on the harness host's OS (macOS 26, cmux-next's swift test lane); classic's
    /// package lane runs on macOS 15, whose Core Animation timings differ (CI run 38761831916: the delivered and
    /// delivered -> read lines begin 6.6 ms later and the receipt shift uses another curve) on unchanged vendored code.
    /// It runs on macOS 26 and later; the Home-against-MessagesLab comparison above runs everywhere.
    @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26,
                   "Golden/home-motion.ndjson is recorded on macOS 26"))
    func theHomePathKeepsItsTypingAndReceiptMotion() throws {
        let b = Self.home()
        var lines = Self.motionTransitions.compactMap { name in
            Self.transitions.firstIndex { $0.name == name }.flatMap { b.animations[checked: $0] }
        }
        // The typing line also holds the indicator's motion over a window (MessagesLab 7cdd49b: it breathes
        // with additive repeating keyframes, which one committed snapshot does not show). The main script's
        // reply ends the indicator 1.2 s after it shows, so the window comes from a run of its own
        // (`typingOnly`, the same Home path): every 2nd tick of the presented row[typing] layers for more
        // than one bubble breathing period (1.906 s). The main script and lines 1, 2, 4 and 5 stay as they were.
        if let i = Self.motionTransitions.firstIndex(of: "typing indicator"), let line = lines[checked: i] {
            lines[i] = "{\"animations\":" + line + ",\"window\":[" + Self.typingWindow(Self.typingOnly().frames).joined(separator: ",") + "]}"
        }
        #expect(lines.count == Self.motionTransitions.count)
        let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden/home-motion.ndjson")
        let now = lines.joined(separator: "\n") + "\n"
        if ProcessInfo.processInfo.environment["HOME_HARNESS_WRITE_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: golden.deletingLastPathComponent(), withIntermediateDirectories: true)
            try now.write(to: golden, atomically: true, encoding: .utf8)
            return
        }
        let recorded = try String(contentsOf: golden, encoding: .utf8)
        if let dir = ProcessInfo.processInfo.environment["HOME_HARNESS_OUT"] {
            try now.write(toFile: dir + "/home-motion.ndjson", atomically: true, encoding: .utf8)
        }
        for (i, name) in Self.motionTransitions.enumerated() {
            let want = recorded.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)[checked: i]
            #expect(lines[checked: i] == want, "the Home motion of \(name) differs from Golden/home-motion.ndjson")
        }
    }
}

/// The presented layer tree and the committed animations of a window view,
/// in the shape of MessagesLab's harness output (its tools/diff-harness is a
/// MessagesLab test driver and is not vendored; scripts/cmux-next/
/// home-messageslab-harness.sh runs it from a MessagesLab checkout).
@MainActor
enum LayerDump {
    static let hidden = 9, opacity = 4

    /// Named layers: rows by key and role, morphs, the compose glass, the clip mask.
    static func named(_ view: MessagesWindowView) -> [(String, CALayer)] {
        var out: [(String, CALayer)] = []
        for case let cell as RowCell in view.collection.visibleCells {
            guard let key = cell.spec?.key, !cell.isHidden else { continue }
            let p = "row[\(key)]"
            out += [(p + "/cell", cell.layer), (p + "/content", cell.contentView.layer), (p + "/bitmap", cell.bitmap),
                    (p + "/fill", cell.fillContainer), (p + "/fillGradient", cell.fillGradient), (p + "/fillMask", cell.fillContainer.mask === cell.fillMaskImage ? cell.fillMaskImage : cell.fillMask),
                    (p + "/connector", cell.connector), (p + "/connectorLine", cell.connectorLine),
                    (p + "/typing", cell.typingContainer), (p + "/typingBody", cell.typingBody), (p + "/typingClip", cell.typingClip), (p + "/receiptOld", cell.receiptOld)]
            for (i, d) in cell.dots.enumerated() {
                out.append((p + "/dot\(i)", d))
                if let hi = d.sublayers?.first { out.append((p + "/dot\(i)/hi", hi)) } // as MessagesLab's harness names it
            }
            // MessagesLab 5f885ea's harness names the typing bubble's tail discs too.
            for (i, d) in cell.typingDiscs.enumerated() { out.append((p + "/disc\(i)", d)) }
        }
        for (key, m) in view.morphs.sorted(by: { $0.key < $1.key }) {
            let p = "morph[\(key)]"
            out += [(p + "/holder", m.holder), (p + "/bubble", m.bubble), (p + "/body", m.body), (p + "/text", m.text),
                    (p + "/blurred", m.blurred), (p + "/tail", m.tail), (p + "/underlay", m.underlay)]
        }
        out += [("compose/glass", view.compose.glass), ("clipMask", view.clipMask), ("transcript", view.collection.layer)]
        return out
    }

    /// One tick: window frame, opacity, transform, corner radius, hidden of every named layer.
    static func frame(_ t: Double, _ view: MessagesWindowView) -> String {
        let root = view.layer
        let items = named(view).map { name, l -> String in
            let f = l.convert(l.bounds, to: root)
            let a = CATransform3DGetAffineTransform(l.transform)
            let v: [Double] = [f.minX, f.minY, f.width, f.height, Double(l.opacity), a.a, a.d, a.tx, a.ty, l.isHidden ? 1 : 0]
            return "\"\(name)\":[" + v.map { $0.isFinite ? String(format: "%.4f", $0) : "0" }.joined(separator: ",") + "]"
        }.sorted()
        return "{\"t\":\(String(format: "%.5f", t)),\"L\":{" + items.joined(separator: ",") + "}}"
    }

    /// Every animation on the named layers as committed: key path, kind,
    /// begin, duration, from/to, spring constants, keyframes, additive.
    static func animations(_ t: Double, _ view: MessagesWindowView) -> String {
        var out: [String: [[String: Any]]] = [:]
        for (n, l) in named(view) {
            var list: [[String: Any]] = []
            for k in l.animationKeys() ?? [] {
                guard let a = l.animation(forKey: k) as? CAPropertyAnimation else { continue }
                var d: [String: Any] = ["keyPath": a.keyPath ?? "", "begin": (a.beginTime * 1e6).rounded() / 1e6,
                                        "duration": (a.duration * 1e6).rounded() / 1e6, "additive": a.isAdditive,
                                        "kind": String(describing: type(of: a))]
                if let s = a as? CASpringAnimation {
                    d["from"] = (s.fromValue as? NSNumber)?.doubleValue ?? 0; d["to"] = (s.toValue as? NSNumber)?.doubleValue ?? 0
                    d["stiffness"] = s.stiffness; d["damping"] = s.damping; d["v0"] = s.initialVelocity
                } else if let b = a as? CABasicAnimation {
                    d["from"] = (b.fromValue as? NSNumber)?.doubleValue ?? 0; d["to"] = (b.toValue as? NSNumber)?.doubleValue ?? 0
                    d["timing"] = b.timingFunction.map { f -> [Float] in
                        var p: [Float] = []
                        for i in 0..<4 { var c: [Float] = [0, 0]; f.getControlPoint(at: i, values: &c); p += c }
                        return p
                    } ?? []
                }
                if let kf = a as? CAKeyframeAnimation {
                    d["values"] = (kf.values as? [NSNumber])?.map(\.doubleValue) ?? []
                }
                list.append(d)
            }
            list.sort { "\($0["keyPath"]!)\($0["begin"]!)\($0["from"] ?? 0)" < "\($1["keyPath"]!)\($1["begin"]!)\($1["from"] ?? 0)" }
            if !list.isEmpty { out[n] = list }
        }
        let obj: [String: Any] = ["t": t, "layers": out]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
