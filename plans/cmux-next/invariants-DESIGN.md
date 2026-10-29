# One invariant framework (CmuxNextInvariants)

Status: design, with migration steps 1 to 5 implemented in part on `cp/invariant-framework` (section 11). Basis:
origin/perf/chrome-parity 8a1900b22f0. The design builds on the focus checker (ab42359a79ce, 7c951d417af8,
train 328). All cost numbers are targets and nobody has measured them.

## 0. Judgement of the three designs

Scores are 1 (bad) to 5 (good).

| Criterion | D1 minimal-first | D2 cost-first | D3 harness-first |
| --- | --- | --- | --- |
| Correctness | 4 | 3 | 4 |
| R1 (one mechanism, old checkers absorbed) | 3 | 5 | 5 |
| Zero cost in Release, bounded cost in DEBUG | 4 | 5 | 4 |
| Harness fails on a violation | 4 | 4 | 5 |
| Easy for a redesign agent to add a rule | 4 | 4 | 5 |
| Total | 19 | 21 | 23 |

- **D3 is the base.** It has an append-only ledger with a sequence cursor, so a harness cannot miss a violation
  between polls. A rule is two parts: a `read` part that gives typed state, and a pure `check` part. When `read`
  returns nil, the rule does not apply now, and that precondition is level state, not a timer. Each owner
  declares its rules next to its own code. The same `read` state is also the R4 parity snapshot.
- **Ideas taken from D2:**
  - A probe that is an empty inlined call in Release.
  - Dirty sets keyed by state (`InvariantKey` x `InvariantSubject`), so a turn runs only the rules whose state
    changed.
  - DEBUG adapters that feed the existing signals into the dirty set, so most producers need no new code.
  - `declare` refuses an IPC or census rule at a per-turn check point.
  - A rule that costs too much is reported as its own violation, `INV-COST`.
  - The `armed` flag.
  - A Rust registry that uses the same ids.
  - Proof of zero Release cost with `nm` on the fleet.
- **Ideas taken from D1:**
  - A memo for each pass, so all input rules share one `InputObservation` walk.
  - A shadow step in the migration before the old monitor goes away.
  - `debug.desync` stays as an alias for one train.
- **Rejected from D2: the 1 ms per-turn cap with carry-over.** When a check moves to a later turn, it can miss a
  transient that clears and can blame the wrong action. That is a throttle, and R5 and CLAUDE.md forbid it. This
  design checks every due rule on every turn. If a rule is too slow, its scope must become smaller.
- **Rejected from D1: no daemon registry.** Without one, the hand-written Rust fuzz checks stay as a second
  mechanism.

## 1. Goal

- Each perf mechanism states its invariant one time, in one place.
- DEBUG and opted-in bench builds check every rule after the commit of each action and after each committed main
  turn. Every frame that can change main-owned state is such a turn.
- Journeys, the focus fuzz, the resize fuzz and the R4 on/off differential fail on any violation. All of them
  read one socket method.
- Release has no checker code, no observer and no rule closures.
- One framework replaces the four checkers that report in four different ways today: InputInvariantMonitor,
  SurfaceInvariantMonitor, WindowInvariants, and the Python and Rust copies.
- Timing never decides correctness (R5). The framework deletes the 200 ms and 500 ms settles and the second
  confirming check. The only timed rule kind is liveness, and a liveness rule only reports.

## 2. API

### 2.1 Package and gating

- Add a new target, `Packages/macOS/CmuxNext/Sources/CmuxNextInvariants/`. It depends only on CmuxNextCompat and
  does not use AppKit. It follows the CmuxNextOracle model.
- Only `InvariantID.swift`, `InvariantKey.swift`, `InvariantSubject.swift` and `InvariantProbe.swift` compile in
  Release. The probe methods are `@inlinable @inline(__always)`, and their bodies are inside
  `#if DEBUG || CMUX_BENCH_HOOKS`. A Release call is an empty inlined call that the compiler removes. Detail
  strings are `@autoclosure`, so a Release call builds no string.
- All other files are inside `#if DEBUG || CMUX_BENCH_HOOKS`.
- App wiring goes in `Sources/CmuxNextApp/Invariants/`, inside the same `#if`.
- One environment variable, `CMUX_NEXT_INVARIANTS`, arms the checks:

| Build | Default | `=1` | `=trap` |
| --- | --- | --- | --- |
| Debug | armed | armed | armed, and traps on a violation |
| Bench (`CMUX_BENCH_HOOKS`) | off | armed | armed, and traps on a violation |
| Release | no code | no code | no code |

`CMUX_NEXT_FOCUS_CHECK=1` stays as an alias of `=1` for one train.

### 2.2 Types

None of these types is a caseless enum or an all-static public type.

```swift
// Compiles in every build.
public struct InvariantID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    // "W10", "LG1", ...
}

public struct InvariantKey: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    // "focus", "visibility", "paneFrame", "grid", "tabs", "presentation", "motion", "windows", "mirror", "hover", "holds"
}

public enum InvariantSubject: Hashable, Codable, Sendable {
    case app, window(String), pane(String), surface(UInt64), page(String), node(UInt64)
}

@MainActor public struct InvariantProbe {   // In Release: an empty struct with empty inlined methods.
    @inlinable @inline(__always)
    public func touch(_ key: InvariantKey, _ subject: InvariantSubject)

    @inlinable @inline(__always)
    public func fail(_ id: InvariantID, _ subject: InvariantSubject,
                     _ detail: @autoclosure () -> String,
                     fileID: StaticString = #fileID, line: UInt = #line)

    @inlinable @inline(__always)
    public func holdBegan(_ hold: InvariantSubject, reason: StaticString)

    @inlinable @inline(__always)
    public func holdEnded(_ hold: InvariantSubject, cause: InvariantHoldEnd)   // X-HOLDEND, section 8
}
```

```swift
// DEBUG || CMUX_BENCH_HOOKS only.
public struct InvariantCheckPoints: OptionSet { .afterAction, .afterTurn, .harness }

public enum InvariantCost { case cheap, walk, ipc, census }

public struct InvariantFinding: Codable {
    let subject: InvariantSubject
    let detail: String
}

public struct InvariantRule {
    public init<State: Encodable & Equatable>(
        id: InvariantID, statement: String, owner: String,
        reads: Set<InvariantKey>, points: InvariantCheckPoints, cost: InvariantCost,
        parity: Bool = true,                                   // the state goes into the R4 snapshot
        read: @escaping @MainActor (InvariantPass) -> State?,  // nil: the rule does not apply now (level precondition)
        check: @escaping (State) -> [InvariantFinding])        // pure, so a unit test can call it

    public static func liveness(
        id: InvariantID, statement: String, owner: String, limit: Duration,
        oldestPending: @escaping @MainActor (InvariantPass) -> [(InvariantSubject, ContinuousClock.Instant)]
    ) -> InvariantRule
}

@MainActor public final class InvariantPass {
    func dirty(_ key: InvariantKey) -> Set<InvariantSubject>  // On checkNow: every subject.
    var trigger: InvariantTrigger
    func memo<T>(_ key: String, _ build: () -> T) -> T       // One build per pass, for example one InputObservation.
}

@MainActor public final class InvariantRegistry {
    func declare(_ rule: InvariantRule)
    // Traps on a duplicate id. Traps on .ipc or .census together with .afterAction or .afterTurn.

    func noteAction(_ cause: InvariantActionCause)  // Stores the cause. Builds no string.
    func touch(_ key: InvariantKey, _ subject: InvariantSubject)
    func runTurn()                                  // Called only by the turn observer.
    func checkNow(ids: Set<InvariantID>?, ipc: Bool) async -> [InvariantViolation]
    func paritySnapshot() -> [InvariantID: Data]    // Canonical JSON of each parity rule's read state.
    let ledger: InvariantLedger
}

public final class InvariantLedger {
    // A ring of 1024 entries with a monotonic seq.
    // A signature (id@host@subject) is reported one time until it clears.
    func report(_ violation: InvariantViolation)
    func report(inline: InvariantViolation)          // For call-site checkers.
    func since(_ seq: UInt64) -> (violations: [InvariantViolation], dropped: Bool)
}

public struct InvariantViolation: Codable {
    let seq: UInt64
    let id: InvariantID
    let host: String                  // "app" | "daemon"
    let subject: InvariantSubject
    let detail: String
    let trigger: InvariantTrigger
    let state: Data?                  // The rule's read state as JSON, at most 4 KB.
    let journalTail: UInt64
    var report: String?               // The report file path, added after the write.
    var signature: String { "\(id.rawValue)@\(host)@\(subject)" }
}

public struct InvariantTrigger: Codable {
    let kind: String                  // "action" | "turn" | "inline" | "liveness" | "check"
    let actions: [InvariantActionCause]  // The last 8 actions of the turn, in run order.
    let turn: UInt64
    let frameSeq: UInt64?
    let fileID: String?
    let line: UInt?
}
```

### 2.3 Where each part lives

- `InvariantTurnObserver` (App): the one observer (section 3).
- `InvariantAdapters` (App, composition root): feed the existing signals into the dirty set (section 3.3).
- `AppInvariants.declareAll(in:services:)` (App): calls each owner's `declareInvariants(in:)` one time.
- Each owner declares its rules in its own `<Owner>+Invariants.swift` file, inside `#if DEBUG || CMUX_BENCH_HOOKS`.
- `InvariantReportStore`: the old `DesyncReportStore` with a new name. It keeps the 50-file limit and the
  off-main `postFiles` write. Its directory is `~/Library/Logs/cmux-next/<tag>/invariants/`.
- `Sources/CmuxNextControl/Diagnostics/InvariantsControl.swift`: serves `debug.invariants` (section 5).

## 3. Check points

### 3.1 One observer: the committed turn

- `InvariantTurnObserver` is one repeating main `CFRunLoopObserver`. It observes `beforeWaiting | exit` in
  `commonModes`, so it also runs during live resize and menu tracking. Its order is **2_000_300**. The other
  observers run before it:
  - the CA commit at 2_000_000
  - `CommitBoundary` at 2_000_001
  - the typing-probe echo at 2_000_100
  - `FramePresentEstimate` at 2_000_200

  So the observer does not change any timing that those observers measure.
- Main-owned state changes only in a main turn. A display-link frame, an action, an event and a daemon apply each
  run as a main turn and end in a CA commit. So a check after each committed turn covers every frame in which the
  model can change. A compositor-driven animation does not change the model off main. The framework adds no
  display link and no frame client. It does not change idle behavior.
- **Idle turn:** no action ran and no key is dirty, so the pass is one bool test. Both observer activities can
  fire in one turn. The second call finds nothing dirty and returns.

### 3.2 After an action

- `ActionRegistry.willRunObservers` (`ActionRunScope.swift:84`) calls `registry.noteAction`. It stores only the
  cause tuple (`ActionID`, origin, run index, entrypoint).
- The observer runs the `.afterAction` rules on the commit of the same turn. The violation names that action.
- A `.waiting` action keeps its cause until the commit of its `mainWork.reply` turn.
- This design does not use the single slots `ActionBudgetMonitor.onCommit` and `runObserver`.
  `ActionCommitWindows` keeps `onCommit`.

### 3.3 After each turn (dirty sets)

- The `.afterTurn` rules run on each turn that has a dirty key, and only on the dirty subjects.
- Rules are indexed by key. A turn runs only the rules whose `reads` contain a touched key.
- The DEBUG adapters in the composition root feed existing signals into the dirty set, so producers need no new
  code. Today these signals call `monitor.noteChange()` in `InputVerificationService.start` (:38-94). After the
  change they call `registry.touch`:

| Signal | Key and subject |
| --- | --- |
| A focus reduction that changes something | `focus`, window |
| A key, mouse-down or mouse-up from the input tap | `focus`, key window |
| A window move, resize, screen change, deminiaturize or backing-scale change | `paneFrame`, window |
| `presentationChanges` | `presentation`, pane |
| PaneController presence and occlusion | `visibility`, pane or window |
| The VisibilityNode `isShown` edge | `visibility`, node |
| A mirror write | `mirror`, `.app` |
| A membership transition | `windows`, `.app` |
| A motion tick (springs, slides) | `motion`, host |
| `DisplayClock.displayDidFire` | sets `frameSeq` |

- A producer that changes state with no existing signal calls `probe.touch(key, subject)` one time, at the write.

### 3.4 Async peers and liveness (R5)

- Some rules compare the model with an async peer: Chromium focus (W4), Chromium geometry (G1) and the daemon
  grid. Such a rule says "model == peer, or a request with a sequence number is in flight". Its `read` returns nil
  while the in-flight ledger holds a request for that subject. Nil is level state, not a delay.
- `InvariantRule.liveness` is the only timed kind (W11/FK3, "presentation settles"). One `MainDeadline` serves the
  earliest due liveness rule. It reports and never changes state.

### 3.5 Harness-only rules

- Rules with cost `.ipc` or `.census` have only `.harness` in their points. Examples: the daemon part of LG1, VS6,
  LO1 (the shim compare), ID4, ID8, PR1-PR3.
- They run only from `debug.invariants {check:true, ipc:true}`. The socket handler collects the replies off main
  and then runs the checks one time on main.
- They never run inside a turn.

### 3.6 Inline call-site checks

These checkers stay at their call sites, because they check a call, not the state after a turn:

- BlockingDetector (ID6)
- RankedMutex (ID7)
- the mirror writer checks (M1)
- `Invariant` (the CmuxSafeConcurrency CHECK tiers)

In DEBUG, their sinks also call `probe.fail` or `ledger.report(inline:)` with trigger kind `inline`. So the
harnesses read one cursor.

## 4. Reporting

On the first turn that shows a signature, the framework does these steps:

1. It appends the violation to the ledger. The violation holds the id, the host, the subject, the detail, the
   trigger and the rule's `read` state. The pass already holds that state, so there is no second walk.
2. It appends `.desync` to `InputJournal` and records the journal index.
3. It writes `logger.fault`.
4. Only for a new signature, it builds the heavy facets one time: the 512-entry journal tail, `DebugFocus`,
   `SurfaceDiagnosticsReport` and `DebugLayers`. It builds them in an `AfterFrameCommit().run` slot after the
   frame, not in the violating turn. Today `record()` builds them on main in the turn; this design stops that.
   JSON encoding and the file write stay off main through `runner.postFiles`.
5. In trap mode (`CMUX_NEXT_INVARIANTS=trap`), it flushes the report for at most 50 ms, as
   `BlockingDetector.trapOnMain` does, then calls `fatalError("invariant <id>: <detail>")`. Use this mode for
   in-process fuzz, XCTest and a local repro under a debugger. Journeys use the cursor, because they need the app
   alive to collect evidence.

More rules:

- A signature is reported one time until a later pass finds it clear. This is the same as `reported` today.
- A rule's p95 above 0.25 ms per run is reported as `INV-COST@<rule id>`. That is a violation and a harness
  failure. The fix is a smaller rule scope.
- `clear:true` resets the set of reported signatures. It never resets `seq`.

## 5. Harness contract

### 5.1 Socket method: `debug.invariants`

Request params (all optional):

| Param | Meaning |
| --- | --- |
| `since: UInt64` | Return the violations with `seq > since`. |
| `check: Bool` | Run the `.afterAction` and `.afterTurn` rules now, on all subjects. |
| `ipc: Bool` | Also run the `.harness` rules. Their reads go off main. |
| `ids: [String]` | Limit `check` to these rules. |
| `rules: Bool` | Include the rule table. |
| `state: Bool` | Include the R4 parity snapshot. |
| `clear: Bool` | Reset the reported signatures. |

Reply:

```json
{
  "armed": true,
  "mode": "on",                     // "on" | "trap" | "off" | "release"
  "seq": 42,
  "oldest_seq": 1,
  "dropped": false,                 // true if since < oldest_seq - 1 (the ring overflowed)
  "turns_checked": 18234,
  "violations": [{
    "seq": 41, "id": "W10", "host": "app",
    "subject": {"window": "w2"}, "detail": "key window model targets none",
    "trigger": {"kind": "action", "actions": [{"id": "pane.split", "origin": "key", "index": 77, "entrypoint": "shortcut"}],
                "turn": 9921, "frame_seq": 4410},
    "state": {"...": "..."}, "report": "~/Library/Logs/cmux-next/<tag>/invariants/0041-W10.json"
  }],
  "rules": [{"id": "W10", "statement": "...", "owner": "InputVerification", "points": ["afterAction"],
             "cost": "walk", "checks": 811, "violations": 1, "us": {"p50": 40, "p95": 120, "p99": 210, "max": 400},
             "interim": null}],
  "state": {"W10": {"...": "..."}, "LG1": {"...": "..."}}
}
```

- A Release build answers `{"armed": false, "mode": "release"}`.
- `debug.desync` is an alias for one train. It maps `check` and `count`, and the `reports[]` from the ledger.
  After that train, delete it (R7). `new-tab-e2e.py` and `input-replay.py` move to `debug.invariants`.
- The daemon serves the same method name and the same payload on its socket, with `"host": "daemon"`
  (section 5.4).

### 5.2 Journeys

- A new helper, `scripts/journeys/invariants.py`, holds a `Cursor` and `assert_clean(app, step)`.
- `driver.py` calls `assert_clean` after each step in the loop at :1468-1490. A new violation raises `StepError`
  with the id, the trigger actions, `frame_seq`, the step and the report path.
- Before the judge (:1513), `driver.py` calls `{check:true, ipc:true, since:cursor}`.
- `dropped: true` fails the journey.
- `armed: false` makes the journey "not run" (exit 75), never a pass.
- `run.py` sets `CMUX_NEXT_INVARIANTS=1` on each launch.
- The app checks every turn and the ledger is append-only. So a read after each step covers every frame in that
  step, and Python needs no per-frame poll.

### 5.3 Focus fuzz (`ext_focus.py`, when cp/journeys-focus-fuzz lands)

- It uses `assert_clean` after each action and adds the seed to the error.
- Delete its Python rules I4 and I5 and the map at :216-253. If W1, W5, W10 or W11 does not cover part of a Python
  rule, declare that part as a Swift rule.
- The probe key (I8) stays as a harness step, not as a rule.

### 5.4 Daemon and the resize fuzz

- Add `cmux-tui/crates/cmux-tui-core/src/invariants.rs`. It holds a list of
  `InvariantRule { id: &'static str, statement: &'static str, check: fn(&Mux) -> Vec<Finding> }`, with the same id
  namespace and violation schema.
- The checks run under `cfg(debug_assertions)` after each sizing flush and each apply.
- The daemon serves them as `debug.invariants`.
- `resize_fuzz.rs` calls `mux.check_invariants()` after each step. `Case::fail` panics on any finding, with the
  seed and the id. Its hand-written checks at :874, :945 and :1013 become declared ids (LG1 daemon part, ID3, VS6).
- The app's `.harness` part of LG1 reads the daemon reply. There is one id and two hosts, not two rules.
- `ext_window.py` `grid_fits` and `pty_size` (:594, :710) are deleted when LG1 lands.

### 5.5 R4 differential

- `scripts/cmux-next/oracle/oracle.py diff --switch NAME` runs each journey and fuzz seed two times, with the
  switch on and then off. This design does not add a CI job.
- Each run must end with 0 violations.
- Then the tool diffs `debug.invariants {state:true}` plus `debug.oracle.snapshot` between the two runs. That
  snapshot comes from the same readers that the invariants use, so no second snapshot path exists (R1).
- Parity state must hold no clock values and no generated ids. A rule whose state cannot be stable declares
  `parity: false`.

## 6. Cost budget

| Item | Budget | How it is held |
| --- | --- | --- |
| Release | 0 framework code. A probe call is an empty inlined call. | A fleet `nm` run on the Release binary shows no `InvariantRegistry`, `InvariantTurnObserver` or rule symbols. The migration PR runs it. It is not a CI gate. |
| Action to commit (< 10 ms) | No change | The pass runs at 2_000_300, after `CommitBoundary` and `FramePresentEstimate`. |
| DEBUG idle turn | < 1 us | One bool test. |
| DEBUG dirty turn | p95 <= 1 ms at STRESS (8 windows x 20 panes). This is a target and it is not measured. | Rules run on dirty subjects only. `memo` gives one shared walk. |
| One rule | p95 <= 0.25 ms per run | A rule above it is reported as `INV-COST`. The fix is a smaller scope. Never throttle the rule, skip turns or carry checks to a later turn. |
| A violation in the turn | Only the rule's state, which the pass already read | Facets are built after the frame. Encoding and the write are off main. |
| Main thread | Never blocks | Rules only read memory. `declare` traps on an `.ipc` or `.census` rule with a per-turn point. |
| Perf evidence | No change | Bench perf runs do not set `CMUX_NEXT_INVARIANTS`. DEBUG timing is not perf evidence. |

Mark `InvariantRegistry.runTurn` with `// perf-hot: 1ms invariants-turn`. Add one bench row in
`scripts/cmux-next/perf-hot-benches.json`. The agent runs that bench on the fleet. It is not a CI gate. The
per-rule histograms are in `rules[].us`.

## 7. Migration of the existing checkers

Each step is its own PR, run on the fleet (cmux-ci, nx-remote). No step adds a CI job, gate or budget.

1. **The framework, with no rules.** Add the target, the registry, the ledger, the turn observer, the adapters,
   `InvariantReportStore`, `debug.invariants` and the `debug.desync` alias. Add
   `plans/cmux-next/invariants-catalog.md`, built from the audit catalog. Run the Release `nm` check.
2. **Input rules, in shadow.**
   - Declare the input rules from `InputInvariantMonitor.check()` (:146-160) one by one, in
     `InputVerification/InputInvariants+Rules.swift`. They call the existing pure functions with no change:
     - W1-W9 through `InputInvariants.world`, with one `InputObservation` per pass through `memo`
     - W10 `keysHaveTarget`
     - W11 as a liveness rule over `FocusExpectationAges`
     - G1 `pageGeometry`, DP1 `tabConservation` and H1 `singleCardViolations`
   - `InputInvariant` keeps its cases and gives `var invariantID`. The ids do not change.
   - Run one journey sweep and one focus-fuzz sweep with the shadow rules beside the old monitor. Some findings
     show on a turn but not after the 200 ms settle. Each such finding is a real bug or a pending state that the
     model does not name. Fix it in the model or with a level precondition, never with a delay.
   - W4 and G1 keep a confirm at the next check point until the Chromium in-flight ledger exists. Their
     `rules[].interim` names that reason.
3. **Delete the monitor's scheduler.** Delete `noteChange`, `settled`, the 200 ms `MainDeadline`, the second
   confirm and `confirming`. `InputInvariantMonitor` goes away. The pure functions and their tests
   (KeysHaveTargetInvariantTests, ChromiumPageFocusInvariantTests, InputReplayTests) stay.
4. **The other checkers.**
   - `SurfaceInvariantMonitor` becomes VS2, on the keys `presentation` and `visibility`. Delete the class and its
     500 ms settle. The `debug.surfaces` counters `invariant_*` read `rules[VS2]`.
   - `WindowInvariants` becomes LO11 at `.afterAction`, on the key `windows`. Its pure predicate stays one
     function. Release behavior is decision 1 in section 10.
   - M1 becomes an inline `probe.fail` in `DaemonStore+MirrorCheck`.
   - The DEBUG sink of BlockingDetector posts ID6 to the ledger.
   - G2 (cp/fix-resize-standin-grid) folds into LG1. G3 is declared as G3. Neither one is a `+=` line.
5. **Harness hooks.** Add `invariants.py`, `driver.py` and `run.py`. Then update `ext_focus.py` when it merges.
   Run the P0 journeys on the fleet.
6. **Daemon.** Add `invariants.rs` and the daemon `debug.invariants`. `resize_fuzz.rs` calls `check_invariants`.
7. **The first three invariants** (section 8).
8. **R4.** Add `oracle.py diff --switch`.
9. **Clean up.** Delete the `debug.desync` alias, the `DesyncReport` naming, the `CMUX_NEXT_FOCUS_CHECK` alias
   and the Python copies.

## 8. The first three invariants after migration

These three guard the most perf mechanisms in the audit catalog. Each one also removes a duplicate predicate or
timer.

1. **X-SHOWN: one definition of "shown".**
   - Guards: visibilityDeferredWork, restoreFrameHold, hiddenTerminalQos, the chromiumHost family (Suggestions,
     PopupMenus, Choosers, Widgets, HangBanner), highEnergyTabs and memorySaverBackgroundActivity. That is about 10
     mechanisms.
   - Rule: on each dirty VisibilityNode, every consumer's cached shown flag equals
     `VisibilityNode.effective > .hidden`. The consumers are terminal pause and `isDrawable`, the blank-pane check,
     the host UI anchors, the host QoS copy and the hibernation `mountedHidden` set.
   - Key: `visibility`. Points: `.afterAction`, `.afterTurn`. Cost: walk on dirty nodes.
   - The same PR deletes the second predicate, the `isHiddenOrHasHiddenAncestor` read with its
     `visibility-walk-allow` comment. It also adds X-OWED: no queued edge closure exists for a shown node. X-OWED
     is a cheap rule on the same key.
2. **LG1: a shown grid fits.**
   - Guards: visibilityDeferredWork, terminalStandIn, paneHoldsContentInMotion, sidebarSlideHoldsContent and
     restoreFrameHold. It also absorbs G2, `ext_window.py` `grid_fits` and `pty_size`, and the resize fuzz checks.
   - Rule: for each shown terminal at rest, the Ghostty grid == fit(bounds at `backingScaleFactor`) == the
     reported grid.
     - App part: keys `paneFrame`, `grid` and `motion`. Points: `.afterAction`, `.afterTurn`. Cost: walk.
     - Daemon part: the daemon grid or the announced lock grid. It is `.harness` in the app and a per-flush rule
       in the daemon.
   - The precondition is level state: `read` returns nil during live resize, a motion hold or a sizing request in
     flight.
3. **X-HOLDEND: a hold ends for a reason, not a timer.**
   - Guards: paneHoldsContentInMotion, sidebarSlideHoldsContent, restoreFrameHold, newTabParksHidden,
     pageStandIn, terminalStandIn and the lagFirstKey key hold. That is 7 mechanisms, and it is the hold, park and
     stand-in pattern of the full audit.
   - Rule: each hold calls `probe.holdBegan` and `probe.holdEnded`. An end with cause `.timeout` is a violation. A
     hold that is open past its liveness limit is reported. Both are reported, never repaired.
   - Key: `holds`. Points: `.afterAction`, `.afterTurn`. Cost: cheap.
   - The hold ledger is the X-LEDGER counter type, and LO1, FK4 and ID5 use it later. LG2, LG3, LG4 and VS3
     refine this rule for each kind of hold.

Next in line: VS5 (6 mechanisms), LO1 (4), and then VS3, LO3 and ID1. Each of those three waits for its
dependency: Ghostty's presented-content mark, the owned-resource ledger, or ID1's change to O(changed). Until then
they are `.harness` only, with `interim` set.

## 9. How a redesign uses the framework

A redesign that cannot state its invariant gets the REMOVE verdict (R3). Otherwise, in the same PR:

1. Pick the id from `plans/cmux-next/invariants-catalog.md`, or add a row there with the statement, the state
   read, the check points and the cost.
2. Declare the rule next to the owner's code:

```swift
// Sources/CmuxNextApp/Panes/PaneHostView+Invariants.swift
#if DEBUG || CMUX_BENCH_HOOKS
extension PaneHosts {
    func declareInvariants(in registry: InvariantRegistry) {
        registry.declare(InvariantRule(
            id: "LG2", statement: "a pane host at rest holds no content size", owner: "Panes",
            reads: ["paneFrame", "motion"], points: [.afterAction, .afterTurn], cost: .walk,
            read: { [unowned self] pass in
                let hosts = pass.dirty("paneFrame").compactMap { host(for: $0) }.filter(\.isAtRest)
                return hosts.isEmpty ? nil : hosts.map(\.geometryFacts)   // [PaneGeometryFacts]: Encodable, Equatable
            },
            check: { facts in
                facts.filter { $0.heldContentSize != nil }
                    .map { InvariantFinding(subject: .pane($0.paneID), detail: "held \($0.heldContentSize!) != clip \($0.clipBounds)") }
            }))
    }
}
#endif
```

3. If no adapter in section 3.3 covers the state, call `probe.touch(key, subject)` one time at the producer. It is a
   no-op in Release.
4. Use only level state as a precondition. Never add a settle, a confirm, a delay or a throttle. A transient that a
   rule finds is either a bug or a pending state that the model must name.
5. Delete the mechanism's own timer, settle, retry or second path. The rule replaces any ad hoc check.
6. Add a unit test that calls `check` on hand-built state. It must fail on the base. Run it on the fleet before and
   after the fix, and write both results in the commit.
7. Run a journey or a fuzz seed on the fleet. It must show the id in `debug.invariants` on the base and a clean
   ledger on the head.
8. If the mechanism has a switch, run `oracle.py diff --switch NAME`.
9. Name the id in the audit verdict row and in the commit.

## 10. Decisions to confirm

1. **WindowInvariants in Release.** Today it logs and counts in every build. The default in this design is to keep
   the same pure predicate as an `Invariant.dumpWillBeCheck` at the transition in Release (Chrome's
   DUMP_WILL_BE_CHECK), with one allowlist entry, and LO11 in DEBUG. Reply `keep the Release CHECK at the
   transition` or `drop the Release log; LO11 is DEBUG only`.
2. **On-demand checks in Release.** Today `debug.desync {check:true}` works in Release. This design removes it,
   because the order says Release has no code path. Field desync reports then stop. Reply `remove on-demand checks
   from Release` or `keep the pure input rules callable from debug.invariants in Release`.
3. **The DEBUG per-turn cap.** This design checks all due rules every turn, with no cap and no carry-over. A slow
   rule is reported as `INV-COST` and its scope must become smaller. Reply `no cap, INV-COST on slow rules` or
   `1 ms cap per turn with carry-over to the next turn (can miss transients)`.
4. **The daemon registry now.** This design builds `invariants.rs` in step 6, so the resize fuzz checks become
   declared ids. Reply `build the daemon registry in step 6` or `keep daemon rules harness-only until after the
   first three invariants land`.
5. **The interim rules.** W4 and G1 keep a next-check-point confirm until the Chromium in-flight ledger exists.
   VS3, LO3 and ID1 stay `.harness` only until their dependency lands. Each one is visible in `rules[].interim`.
   Reply `accept these interim rules` or `block the matching redesigns until each dependency lands`.
6. **Facts not confirmed.** Nobody has confirmed whether the fleet journey artifact is a Debug build or a bench
   build. `run.py` sets `CMUX_NEXT_INVARIANTS=1`, and that covers both. Nobody has measured the cost targets in
   section 6. The first fleet sweep in migration step 2 measures them.

## 11. Implementation on `cp/invariant-framework`

This branch implements steps 1 to 3, step 4 except the BlockingDetector sink (VS2, LO11 and M1 are declared;
`SurfaceInvariantMonitor` and its 500 ms settle are deleted), and step 5 for journeys and the macOS fuzz
(`invariants.py`, `driver.py`, `run.py`, `fuzz.py`). Where the code differs from sections 2 to 7, this list says why.

- **Turn observer in the package.** `InvariantTurnObserver` is in `CmuxNextInvariants`, not the App: the
  `app-size` guardrail refuses a new App file that is not a move, and the observer needs only
  `MainRunLoopObserver` (CmuxNextCompat). The App only constructs it, and only when the registry is armed.
- **The wiring lives in the packages.** The world check (`InputInvariants+World`), the input rules
  (`InputInvariants.declaredRules(world:)`, `expectationRule`), the observation reuse (`InputObservationReuse`) are
  in CmuxNextInputModel; the report pipeline (`InvariantReporter`: one capture turn per batch, the files lane's
  encoding, the ledger's annotation) is in CmuxNextInvariants. The App only builds the observation from its live
  state, names the facets and passes its scheduler: CmuxNextApp does not grow (check-app-size.sh `--base`).
- **No App `Invariants/` folder and no `AppInvariants` type,** for the same reason. The input rules are declared
  by `InputVerificationService.declareInvariants(in:services:)` (InputVerificationService.swift); G1 by
  `ChildPageGeometry.declareInvariants(in:services:)`; DP1 by `DebugTabDrag.declareInvariants(in:services:)`;
  H1 by `HoverCardCoordinator.declareInvariants(in:)` (CmuxNextDesign, the owner, over the pure
  `HoverCardFacts.violations`).
- **The registry is built in `AppServices.init`** (`InputVerificationService.makeInvariants`, the composition
  root), with every rule declared, so `debug.invariants` answers `armed` from the first request. The
  `InputVerification.start` post only wires the signals and the turn observer.
- **Coverage, not intersection.** A signature clears only when a run looked at its subject: a `read` that asks
  `pass.dirty(key)` covers only those subjects, `pass.checked(_:)` names the ones it read, `pass.skip(_:)` leaves
  one out (a window in a live resize), and a read that asks nothing covers every subject. A liveness wait keeps its
  start until a run looks at its subject. A liveness limit runs a full pass.
- **No confirm at the next check point.** W4 and G1 compare the model with Chromium, whose replies are async, and
  no in-flight ledger names that wait yet: they are `.harness` rules (`interim`), run by `debug.invariants {check:
  true}` after each journey and fuzz step, where the step already waited, and never in a turn.
- **Deferred states are level state.** A pane whose content is owed (`TabContentCache.pendingBrowsers`: a Ctrl-`
  stand-in's page after its first frame commits, or a page waiting for its engine; or a Chromium browser not
  created yet, `CEFPaneHost.createAfterCommit`) is `InputObservation.Window.owed`: its window is unsettled, so
  W1-W4 and W8 do not read it and W9 bounds the wait. The P0 shadow sweep lists any deferral this misses.
- **One world check per pass.** All input rules read `pass.memo("input.world")` and take their own id's share.
  `InputInvariants.violations(of:in:)` and its switch are deleted; an id the world check reports that no rule
  declares is `INV-UNDECLARED`, never dropped. The observation rebuilds only the windows a turn touched, the key
  window and the active one; the producers touch the real subject (the key window, the moved window, the panes
  that present a changed tab).
- **Reports off the violating turn.** A pass hands its new violations over as one batch; the rule state stays
  typed. One `.background` main task after the frame reads the facets once for every waiting violation, and the
  files lane encodes the states and the report and writes it; the ledger names the report (and keeps a state of
  at most 4 KB) only once the file exists.
- **Cost of the pass.** The pass's p95, memo builds included, above 1 ms is `INV-COST@pass`. A rule's p95 test
  is one comparison (a count of runs over the limit). The ledger is a ring that overwrites one slot; the action
  causes are fixed rings, so `noteAction` allocates nothing in an unarmed bench build. The pass runs inside the
  turn meter's `debugCheck` span (`debug.main_budget` `turn_ms.debug_check_total`), so it is neither render nor
  unattributed time.
- **A rule names its prove-or-remove rows** (`row: "pNN-NN"` or `rows: [...]`, a literal in the declaration):
  the generated prove-or-remove table (gen-table.py `declared_rows`) reads invariant ids only from the
  declarations; `debug.invariants {rules: true}` lists them. G1 names p11-11 (child-page geometry per window);
  the input rules (computed ids), DP1, H1, VS2 and LO11 name none yet: no row clearly owns their mechanism.
- **The probe is injected, not global.** A global probe sink is a stateful static (the arch ratchet's
  `stateful_singletons` row). `InvariantProbe(registry:)` is a value the composition root hands to each producer
  (`DaemonStore.invariants` through `MachineRegistry.invariants`, `HoverCardCoordinator.invariants`,
  `InputVerificationService.probe`); in Release it is an empty struct and `InvariantProbe()` is its only
  initializer. `InvariantReleaseTests` checks its size is 0 in a Release test build;
  `scripts/cmux-next/check-invariants-release-symbols.sh APP` is the `nm` check of section 6.
- **No shadow step in the app.** The task order was to delete the old monitor in the same change (no second
  path). The shadow step is in the harness: `driver.py --invariants shadow` (the default until the P0 sweep's
  findings are fixed or named) records each violation in the journey's result and goes on; `--invariants fail`
  fails the step. The cursor belongs to the app process (carried across journeys), and a relaunch step reads the
  old ledger before the quit.
- **W9 (presentation settles) is a liveness rule** with the old settle as its limit (200 ms): an unsettled window
  is a pending state, and reporting it per turn would report every switch. W1-W3 and W8 skip an unsettled window
  (level precondition, as before).
- **The world rules read the whole observation.** W1-W8, W10 and the F rules read one memoized
  `InputObservation` of every window when any of `focus`, `presentation` or `paneFrame` is dirty: a change in one
  window (the key window) can break a rule in another, so they do not filter by subject. Each rule runs only its
  own family of `InputInvariants.world` (`InputInvariants.violations(of:in:)`; `InputInvariantRulesTests` proves
  the rules together find what `world` finds). Their state holds window and pane ids, so they declare
  `parity: false`.
- **A turn with an action is a full pass**: an action can change any state, so its `.afterAction` rules see every
  subject (`InvariantPass.isFull`).
- **Action causes** carry the action id, its origin and the registry's own run index; `ActionRegistry.willRunObservers`
  does not pass the entrypoint, and a `.waiting` action's cause is not kept until its reply's turn yet.
- **W11 runs only through the registry** (`InputVerificationService.expectationRule`); `FocusExpectationAges.check`
  is deleted and the W11 tests drive the rule through a registry with their own clock.
- **VS2 is a liveness rule** (500 ms, the old settle as its limit): a blank pane is pending while its content
  attaches or paints, and only a pane still blank at its limit is a violation. `debug.surfaces`
  `invariant_violations` and `invariant_checks` read `rules[VS2]`.
- **LO11** checks the window invariants after each action and each turn a membership transition touched. A
  Release or unarmed bench build keeps the log at the transition (decision 1, default).
- **M1 in an unarmed bench build:** a call-site report goes to the ledger armed or not.
- **The Release check** (`check-invariants-release-symbols.sh`) reads the symbols and every string (type
  descriptor names survive stripping), requires the Release types (`InvariantsControl`, `InvariantProbe`,
  `debug.invariants`) as a positive control, fails on a read error, and with `--control DEBUG_APP` proves it
  finds the checker in a Debug build.
- **The named keys** are `@_alwaysEmitIntoClient` computed values and the Release journal tap passes no press
  closure, so a Release probe call reads no global.
- **`frame_seq` is null**: no `DisplayClock.displayDidFire` adapter yet.
- **`debug.invariants` before the registry starts** (the `InputVerification.start` launch post may come after the
  control methods are registered) answers `{"armed": false, "mode": "starting"}`.
- **No trap mode yet.** `fatalError` is a banned crash class (scripts/cmux-next/crash-allowlist.json): the trap
  needs an allowlist entry signed off by the crash lead or a review subagent, as BlockingViolationTable's has.
  Until then only `CMUX_NEXT_INVARIANTS=1` arms a bench build (`=trap` does not), and `mode` is `on` or `off`.
  In-process tests read the ledger instead.
- **The report store is in the package** (`CmuxNextInvariants/InvariantReportStore.swift`), not the App, for the
  `app-type` rule; the App's sorted-key encoder moved from `DesyncReport` to `AppControl.encoder`.
- **Harness rules** are declared with `InvariantRule.harness(...)`, whose `read` is async; none exists yet.
- **Journeys** ship `invariants.py` with the driver; `run.py --skip-invariants` (driver `--skip-invariants`) plays a
  build from before `debug.invariants` unchecked. `run.py` does not set `CMUX_NEXT_INVARIANTS`: capture-host's
  `launch --env` accepts only `ACPMUX_HOME` and `XDG_CONFIG_HOME`. Fleet journey builds are Debug builds
  (`cmux-ci build cmux` without `--release`), which are armed by default; a bench build is "not run".
- **Not done:** the BlockingDetector sink (ID6), `ext_focus.py` (not on the base), the daemon registry, the R4
  tool, `invariants-catalog.md`, the `DisplayClock` frame adapter, the per-subject adapters of section 3.3 for
  motion and grid, the Chromium in-flight ledgers (W4 and G1 back to per-turn rules), trap mode, and the three
  invariants of section 8.
