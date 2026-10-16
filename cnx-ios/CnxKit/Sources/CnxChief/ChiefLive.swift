import Foundation

/// What Chief is doing right now, as the conversation shows it while a run
/// works (Live frames v1, `chief-live-v1`): the reply text so far and the
/// compact "working on" line. Ephemeral: never a message; the final reply
/// arrives as a normal message and the run's end clears this.
public struct ChiefLive: Equatable, Sendable {
    /// The run, as conversation + author + run (run ids repeat across Chiefs).
    public var key: String
    /// The talk step that text belongs to (nil: activity only).
    public var step: String?
    /// The newest talk step's text so far (thought text is never shown).
    public var text: String
    /// The owner cut the step's older text from its buffer: show "…" first.
    public var truncated: Bool
    /// "Editing src/app.ts in sb-3"; nil before the first activity frame.
    public var activity: String?
    /// When that activity began; the client draws the elapsed time itself.
    public var since: Date?

    public init(key: String, step: String? = nil, text: String, truncated: Bool = false, activity: String? = nil, since: Date? = nil) {
        self.key = key
        self.step = step
        self.text = text
        self.truncated = truncated
        self.activity = activity
        self.since = since
    }
}

/// The live state of one conversation's running Chief runs, built from
/// `step.delta`, `run.activity`, `run.live` and `conversation-run-changed`
/// frames. Pure: frames in, the state and whether to ask again out.
struct ChiefLiveState {
    struct Step {
        var kind: String
        var seq: Int
        var text: String
    }

    struct Run {
        var steps: [String: Step] = [:]
        /// Step ids in the order their text began (the newest talk shows).
        var order: [String] = []
        /// Steps whose Step row arrived: later deltas for them are dropped.
        var done: Set<String> = []
        var activity: (line: String, since: Date)?
        var touched: Int
    }

    let conversation: String
    private(set) var runs: [String: Run] = [:]
    /// Runs that ended: a late frame never opens them again.
    private var ended: [String] = []
    private var tick = 0
    /// What the owner keeps per step (64 KiB of tail text).
    static let bufferCap = 64 * 1024

    init(conversation: String) {
        self.conversation = conversation
    }

    static func key(author: String, run: String) -> String { "\(author)\u{0}\(run)" }

    /// What happened to a frame.
    enum Outcome: Equatable {
        case changed
        case ignored
        /// A `seq` gap or a step reset: ask `run.live.get` and replace with its answer.
        case resync
    }

    /// A rising stamp: the run touched last is the one shown.
    private mutating func touch() -> Int {
        tick += 1
        return tick
    }

    /// `step.delta`.
    mutating func delta(_ frame: [String: Any]) -> Outcome {
        guard frame["conversation"] as? String == conversation,
              let run = frame["run"] as? String, let step = frame["step"] as? String,
              let seq = (frame["seq"] as? NSNumber)?.intValue, let text = frame["text"] as? String else { return .ignored }
        let kind = frame["kind"] as? String ?? "talk"
        let key = Self.key(author: frame["author"] as? String ?? "", run: run)
        guard !ended.contains(key) else { return .ignored }
        var live = runs[key] ?? Run(touched: 0)
        live.touched = touch()
        guard !live.done.contains(step) else { return .ignored }
        var outcome = Outcome.changed
        if var current = live.steps[step] {
            if seq == 0 {
                // A retried model request restarts the step; the owner sends
                // a fresh `run.live` too, and the answer to ours replaces this.
                current = Step(kind: kind, seq: 0, text: text)
                outcome = .resync
            } else if seq <= current.seq {
                return .ignored
            } else if seq == current.seq + 1 {
                current.seq = seq
                current.text = Self.capped(current.text + text)
            } else {
                runs[key] = live
                return .resync
            }
            live.steps[step] = current
        } else if seq == 0 {
            live.steps[step] = Step(kind: kind, seq: 0, text: text)
            live.order.append(step)
        } else {
            // Joined mid-step without its text: the snapshot has it.
            runs[key] = live
            return .resync
        }
        // A thought has no Step row on Cloud: its final delta ends it.
        if frame["final"] as? Bool == true, kind == "thought" {
            live.steps[step] = nil
            live.order.removeAll { $0 == step }
            live.done.insert(step)
        }
        runs[key] = live
        return outcome
    }

    /// `run.activity`: newest wins.
    mutating func activity(_ frame: [String: Any]) -> Outcome {
        guard frame["conversation"] as? String == conversation,
              let run = frame["run"] as? String, let line = frame["line"] as? String, !line.isEmpty else { return .ignored }
        let key = Self.key(author: frame["author"] as? String ?? "", run: run)
        guard !ended.contains(key) else { return .ignored }
        var live = runs[key] ?? Run(touched: 0)
        live.touched = touch()
        let since = (frame["since"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? Date()
        live.activity = (line, since)
        runs[key] = live
        return .changed
    }

    /// `run.live`: replaces every live run with the owner's buffer.
    mutating func snapshot(_ frame: [String: Any]) -> Outcome {
        guard frame["conversation"] as? String == conversation else { return .ignored }
        var next: [String: Run] = [:]
        for entry in frame["runs"] as? [[String: Any]] ?? [] {
            guard let run = entry["run"] as? String else { continue }
            let key = Self.key(author: entry["author"] as? String ?? "", run: run)
            guard !ended.contains(key) else { continue }
            let stamp = touch()
            var live = Run(touched: stamp)
            // Steps whose rows already arrived stay ended.
            live.done = runs[key]?.done ?? []
            for step in entry["steps"] as? [[String: Any]] ?? [] {
                guard let id = step["step"] as? String, !live.done.contains(id),
                      let seq = (step["seq"] as? NSNumber)?.intValue else { continue }
                live.steps[id] = Step(kind: step["kind"] as? String ?? "talk", seq: seq, text: step["text"] as? String ?? "")
                live.order.append(id)
            }
            if let activity = entry["activity"] as? [String: Any], let line = activity["line"] as? String, !line.isEmpty {
                let since = (activity["since"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? Date()
                live.activity = (line, since)
            }
            next[key] = live
        }
        runs = next
        return .changed
    }

    /// `conversation-run-changed`: a terminal run ends its live state; a
    /// talk or thought Step row ends that step (the row is the text now).
    mutating func runChanged(_ frame: [String: Any]) -> Outcome {
        guard frame["conversation"] as? String == conversation, let run = frame["run"] as? [String: Any],
              let id = run["id"] as? String else { return .ignored }
        let key = Self.key(author: run["author"] as? String ?? "", run: id)
        if let status = run["status"] as? String, status != "running" {
            runs[key] = nil
            ended.append(key)
            if ended.count > 256 { ended.removeFirst(ended.count - 256) }
            return .changed
        }
        let rows = (frame["steps"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            .filter { $0.hasPrefix("talk:") || $0.hasPrefix("thought:") }
        guard !rows.isEmpty else { return .ignored }
        let stamp = touch()
        var live = runs[key] ?? Run(touched: stamp)
        for step in rows {
            live.steps[step] = nil
            live.order.removeAll { $0 == step }
            live.done.insert(step)
        }
        runs[key] = live
        return .changed
    }

    /// The run the conversation shows: the most recently touched one with
    /// talk text or an activity line.
    var current: ChiefLive? {
        let shown = runs.filter { _, run in
            run.activity != nil || run.order.contains { run.steps[$0]?.kind == "talk" }
        }
        guard let newest = shown.max(by: { $0.value.touched < $1.value.touched }) else { return nil }
        let key = newest.key
        let run = newest.value
        let talkID = run.order.last { run.steps[$0]?.kind == "talk" }
        let talk = talkID.flatMap { run.steps[$0] }
        return ChiefLive(
            key: "\(conversation)\u{0}\(key)", step: talkID, text: talk?.text ?? "",
            truncated: (talk?.text.utf16.count ?? 0) > Self.bufferCap,
            activity: run.activity?.line, since: run.activity?.since
        )
    }

    /// The owner keeps 64 KiB of tail text per step; so does this.
    static func capped(_ text: String) -> String {
        let units = text.utf16
        guard units.count > bufferCap else { return text }
        var start = units.index(units.endIndex, offsetBy: -bufferCap)
        // Never start inside a surrogate pair.
        if UTF16.isTrailSurrogate(units[start]) { start = units.index(after: start) }
        return String(text[start...])
    }
}

/// The live state a backend reports, read by ``ChiefSession`` (as
/// ``ChiefQuestionFeed`` is): one handler, called after every change.
public final class ChiefLiveFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var live: ChiefLive?
    private var handler: (@Sendable (ChiefLive?) -> Void)?

    public init() {}

    public var current: ChiefLive? { lock.withLock { live } }

    /// Calls `handler` with the state now and after every change.
    public func observe(_ handler: @escaping @Sendable (ChiefLive?) -> Void) {
        let now = lock.withLock {
            self.handler = handler
            return live
        }
        handler(now)
    }

    func update(_ next: ChiefLive?) {
        let handler: (@Sendable (ChiefLive?) -> Void)? = lock.withLock {
            guard live != next else { return nil }
            live = next
            return self.handler
        }
        handler?(next)
    }
}

/// A backend whose conversation carries Chief's live frames.
public protocol ChiefLiveSource: AnyObject, Sendable {
    var liveFeed: ChiefLiveFeed { get }
}
