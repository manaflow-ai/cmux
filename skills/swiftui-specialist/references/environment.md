# Environment Performance

## How environment comparison works

When an environment value propagates, SwiftUI compares the old and new value to decide whether each reader needs to re-evaluate. Four facts about that comparison drive the rest of this document:

- **Structs compare field-by-field.** A non-`Equatable` struct whose fields all look equal compares as equal — `Equatable` is a fast path, not a prerequisite.
- **Class references compare by identity.** Two references to the same instance are equal; reassigning to a freshly-allocated instance is not.
- **Function values (closures) can't be compared reliably.** SwiftUI treats each re-read as changed, and every reader in the subtree invalidates.
- **Every environment write propagates to the whole subtree.** When any key changes, readers re-read their keys. A reader that falls back to its *default* gets that default re-evaluated on every pass — so an unstable default invalidates on every unrelated env write.

The same model covers `EnvironmentValues` / `@Environment` and `FocusedValues` / `@FocusedValue`. Rules in the sections below apply to both.

## Closures in the Environment

This section is about **custom** environment and focus-value keys that you define. Framework-provided action types — `OpenURLAction`, `DismissAction`, `RefreshAction`, and similar — are designed to wrap a closure and pair with framework-provided keys (`\.openURL`, `\.dismiss`, `\.refresh`, etc.). Passing a closure to one of these is the intended API and is **not** the anti-pattern below. Do not propose defunctionalizing them, replacing them with a custom struct or protocol, or avoiding the matching framework key. Before flagging a closure-in-environment site, check whether the receiving key is framework-provided; if it is, skip this rule.

Never store closures or function values in your own custom environment keys. The same applies to `FocusedValueKey`. Closures can't be reliably compared, so views that read that environment key may invalidate, even if nothing has changed. The comparison heuristics are different depending on the level of compiler optimization, and vary for different signatures and captures. The rule is unconditional — even when a specific closure happens to compare equal right now (non-capturing no-ops often do), you have no control over future writer sites adding captures, and the framework gives you no way to guarantee otherwise. Don't attempt to engineer a way to make putting a closure in the environment or focus values work. Wrapping the closure as a stored property on a struct is also not an acceptable fix — the struct still contains a closure, so comparison still fails. The fix is to eliminate the closure entirely: store the data it would have captured as properties on a struct or model, and expose the behavior as a regular method or `callAsFunction`.

The shape of the fix depends on the construction of the closure at the call site.

The same FIX patterns apply to `FocusedValueKey`: substitute `FocusedValues` / `@FocusedValue` for `EnvironmentValues` / `@Environment` in any example below.

`@MainActor` on the `@Observable` classes in the examples below is the defensive default and is safe to keep. When the class is only read and mutated from view bodies (as is typical), the annotation can be omitted without losing correctness.

### Not a fix: Wrapping the closure in a struct

A struct that stores a closure as a property has the same problem as putting the closure directly in `@Entry` — the closure inside the struct still defeats comparison, and every body evaluation constructs a new struct with a freshly-allocated closure. SwiftUI treats the environment value as changed on every write, and every view that reads it invalidates.

```swift
// AVOID: A struct that stores a closure is not a real fix.
// The closure property still can't be compared, so FormFields
// invalidates on every body evaluation of FormContainer.

struct SubmitAction {
    var perform: (String) -> Void
}

extension EnvironmentValues {
    @Entry var submitAction = SubmitAction(perform: { _ in })
}

struct FormContainer: View {
    var body: some View {
        FormFields()
            .environment(\.submitAction,
                SubmitAction(perform: { print("Submit: \($0)") }))
    }
}
```

Use one of the FIX shapes below instead: store the data the closure would have captured as stored properties, and expose the behavior via a regular method or `callAsFunction` (with no closure property).

### Not a fix: Hoisting the closure to a stored property on the View

Lifting the closure to a `private let action: () -> Void = { ... }` on the `View` struct is not a fix either. SwiftUI re-instantiates `View` structs freely, so the `let` initializer re-runs and produces a fresh closure each time the struct is constructed; even when the pointer happens to be stable, closure comparison heuristics still treat them as unequal under some optimization levels. This is the same trap as wrapping in a struct — same conclusion, same fix.

### EXAMPLE: Closure with NO captures

```swift
// AVOID: Storing a closure in the environment.
// Closures can't be compared and all views that read this key will be invalidated even when the closure hasn't changed.

extension EnvironmentValues {
    @Entry var submitAction: (String) -> Void = { _ in }
}

struct FormContainer: View {
    var body: some View {
        FormFields()
            .environment(\.submitAction) { draft in
                print("Submit: \(draft)")
            }
    }
}

struct FormFields: View {
    // This view is always invalidated: SwiftUI cannot compare the closure
    // in submitAction, so it assumes the value changed every time.
    @Environment(\.submitAction) private var submit

    var body: some View {
        Button("Submit") { submit("hello") }
    }
}
```

### FIX: Closure with NO captures

**Option A: Defunctionalize into a struct with `callAsFunction`:**

```swift
// PREFER: A struct with callAsFunction keeps call-site ergonomics.
// SwiftUI can compare the struct's stored properties to skip redundant
// invalidation
struct SubmitAction {
    func callAsFunction(_ draft: String) {
        print("Submit: \(draft)")
    }
}

extension EnvironmentValues {
    @Entry var submitAction = SubmitAction()
}

struct FormContainer: View {
    var body: some View {
        FormFields()
            .environment(\.submitAction, SubmitAction())
    }
}

struct FormFields: View {
    @Environment(\.submitAction) private var submit

    var body: some View {
        // Reads like a closure call thanks to callAsFunction.
        Button("Submit") { submit("hello") }
    }
}
```

**Option B: Use an @Observable model:**

```swift
// PREFER: Use an @Observable model to hold the action.
// The model reference is compared by identity, so the environment value
// is stable and dependent views do not spuriously invalidate.
@MainActor
@Observable
final class FormHandler {
    func submit(_ draft: String) {
        print("Submit: \(draft)")
    }
}

struct FormContainer: View {
    @State private var handler = FormHandler()

    var body: some View {
        FormFields()
            .environment(handler)
    }
}

struct FormFields: View {
    @Environment(FormHandler.self) private var handler

    var body: some View {
        Button("Submit") { handler.submit("hello") }
    }
}
```

**Choosing between A and B:** Prefer Option A when the action is stateless and self-contained. Prefer Option B when the handler needs to coordinate with other state on a shared model, or when you want to reuse the same model for related functionality.

### EXAMPLE: Closure WITH captures

```swift
// AVOID: Storing a closure in the environment.
// Closures can't be compared and all views that read this key will be invalidated even when the closure hasn't changed.

extension EnvironmentValues {
    @Entry var submitAction: () -> Void = {}
}

struct FormContainer: View {
    @State private var draft = "hello"

    var body: some View {
        FormFields()
            .environment(\.submitAction) {
                print("Submit: \(draft)")
            }
    }
}

struct FormFields: View {
    // This view is always invalidated: SwiftUI cannot compare the closure
    // in submitAction, so it assumes the value changed every time.
    @Environment(\.submitAction) private var submit

    var body: some View {
        Button("Submit") { submit() }
    }
}
```

### FIX: Closure WITH Captures

**Option A: Defunctionalize into a struct with `callAsFunction`, and captures stored as properties on the struct:**

```swift
// PREFER: A struct with callAsFunction keeps call-site ergonomics.
// Store the previously captured @State as a property on the struct.

struct SubmitAction {
    var draft: String
    
    func callAsFunction() {
        print("Submit: \(draft)")
    }
}

extension EnvironmentValues {
    // `submitAction` is optional here because the action is invalid
    // without the draft value set. When fixing this issue optionality
    // should always be considered based on the context. This example
    // does not imply that the entry *must* be optional in all cases.
    @Entry var submitAction: SubmitAction?
}

struct FormContainer: View {
    @State private var draft = "hello"

    var body: some View {
        FormFields()
            .environment(\.submitAction, SubmitAction(draft: draft))
    }
}

struct FormFields: View {
    @Environment(\.submitAction) private var submit

    var body: some View {
        // Reads like a closure call thanks to callAsFunction.
        Button("Submit") { submit?() }
    }
}
```

**Option B: Use an @Observable model, with captures moved into the model as observable properties:**

```swift
// PREFER: Use an @Observable model to hold the action.
// Move the previously captured @State from the view into the model.

@MainActor
@Observable
final class FormHandler {
    var draft: String = "hello"

    func submit() {
        print("Submit: \(draft)")
    }
}

struct FormContainer: View {
    @State private var handler = FormHandler()

    var body: some View {
        FormFields()
            .environment(handler)
    }
}

struct FormFields: View {
    @Environment(FormHandler.self) private var handler

    var body: some View {
        Button("Submit") { handler.submit() }
    }
}
```

**Choosing between A and B:** Prefer Option A when the captured state is small, view-local, and not shared with other views. Prefer Option B when the state naturally belongs outside the view — multiple readers or writers, external mutation, or when you want `@Observable` per-property tracking across the subtree.

### EXAMPLE: Advanced Use Case With Generic Handler

In this case, the closure, `appearanceHandler`, is completely different depending on the view into which it's injected.

```swift
class MetricsTracker {
    func trackForm(name: String) { /* ... */ }
    func trackCart(itemCount: Int) { /* ... */ }
}

extension EnvironmentValues {
    @Entry var appearanceHandler: () -> Void = {}
}

struct MainView: View {
    @State private var tracker = MetricsTracker()
    @State private var formName = "Form1"
    @State private var cartItemCount = 0
    
    var body: some View {
        VStack {
            FormFields(name: formName)
                .environment(\.appearanceHandler) {
                    tracker.trackForm(name: formName)
                }
            ShoppingCart(itemCount: cartItemCount)
                .environment(\.appearanceHandler) {
                    tracker.trackCart(itemCount: cartItemCount)
                }
        }
    }
}

struct FormFields: View {
    // This view is always invalidated: SwiftUI cannot compare the closure
    // in appearanceHandler, so it assumes the value changed every time.
    @Environment(\.appearanceHandler) private var appearanceHandler
    
    let name: String
    
    var body: some View {
        Text(name)
        FormContent()
            .onAppear {
                appearanceHandler()
            }
    }
}

struct ShoppingCart: View {
    let itemCount: Int
    @Environment(\.appearanceHandler) private var appearanceHandler
    
    var body: some View {
        Text("Item Count: \(itemCount)")
        ItemList()
            .onAppear {
                appearanceHandler()
            }
    }
}
```

### FIX: Advanced Use Case With Generic Handler

**Option A: Defunctionalize into separate structs conforming to a shared protocol**
 
In cases where a closure is stored that could have an entirely different implementation depending on the context, generalize the closure into a handler that conforms to a 
protocol, and declare a conforming concrete implementation that encapsulates the captures.

The type of the @Entry should be the protocol, while the concrete types that conform to the protocol are injected into the environment for each view.

Within Option A, choose between `callAsFunction` and a named method based on call-site readability. Use `callAsFunction` when you're replacing an existing closure call site and want to preserve the `handler(x)` ergonomics. Use a named method (for example, `handleURL(_:)`, `onAppear()`, `submit(_:)`) when the protocol describes a specific, nameable operation — the call site `handler.handleURL(url)` reads better than `handler(url)` when the behavior isn't obvious from surrounding context.

```swift
class MetricsTracker {
    func trackForm(name: String) { /* ... */ }
    func trackCart(itemCount: Int) { /* ... */ }
}

protocol AppearanceHandler {
    func callAsFunction()
}

extension EnvironmentValues {
    @Entry var appearanceHandler: AppearanceHandler?
}

struct FormAppearanceHandler: AppearanceHandler {
    let tracker: MetricsTracker
    let name: String
    
    func callAsFunction() {
        tracker.trackForm(name: name)
    }
}

struct CartAppearanceHandler: AppearanceHandler {
    let tracker: MetricsTracker
    let itemCount: Int
    
    func callAsFunction() {
        tracker.trackCart(itemCount: itemCount)
    }
}

struct MainView: View {
    @State private var tracker = MetricsTracker()
    @State private var formName = "Form1"
    @State private var cartItemCount = 0
    
    var body: some View {
        VStack {
            FormFields(name: formName)
                .environment(\.appearanceHandler,
                    FormAppearanceHandler(tracker: tracker, name: formName))
            ShoppingCart(itemCount: cartItemCount)
                .environment(\.appearanceHandler,
                    CartAppearanceHandler(tracker: tracker, itemCount: cartItemCount))
        }
    }
}

struct FormFields: View {
    @Environment(\.appearanceHandler) private var appearanceHandler
    
    let name: String
    
    var body: some View {
        Text(name)
        FormContent()
            .onAppear {
                appearanceHandler?()
            }
    }
}

struct ShoppingCart: View {
    let itemCount: Int
    @Environment(\.appearanceHandler) private var appearanceHandler
    
    var body: some View {
        Text("Item Count: \(itemCount)")
        ItemList()
            .onAppear {
                appearanceHandler?()
            }
    }
}
```

**Option B: Unify related state and logic into a shared class**
 
In many cases, rethinking the way that data is modeled can eliminate the need for overly complex open ended closure-based implementations. Grouping together related properties into a unified source of truth can make it easier to avoid making things unnecessarily generic in a way that is more compatible with how SwiftUI performs view comparison.

```swift
class MetricsTracker {
    func trackForm(name: String) { /* ... */ }
    func trackCart(itemCount: Int) { /* ... */ }
}

@MainActor
@Observable
final class Model {
    private let tracker = MetricsTracker()
    
    var formName: String = "Form1"
    var cartItemCount: Int = 0
    
    func trackFormAppearance() {
        tracker.trackForm(name: formName)
    }
    
    func trackCartAppearance() {
        tracker.trackCart(itemCount: cartItemCount)
    }
}

struct MainView: View {
    @State private var model = Model()
    
    var body: some View {
        VStack {
            FormFields()
            ShoppingCart()
        }
        .environment(model)
    }
}

struct FormFields: View {
    @Environment(Model.self) private var model
    
    var body: some View {
        Text(model.formName)
        FormContent()
            .onAppear {
                model.trackFormAppearance()
            }
    }
}

struct ShoppingCart: View {
    @Environment(Model.self) private var model
    
    var body: some View {
        Text("Item Count: \(model.cartItemCount)")
        ItemList()
            .onAppear {
                model.trackCartAppearance()
            }
    }
}
```

**Choosing between A and B:** Prefer Option A (protocol + concrete handlers) when handler kinds are independent and the set is open — for example, if third parties may add new handlers. Prefer Option B (unified model) when the handlers share state (such as the common `tracker` here) and the set is closed; it avoids the existential and usually shrinks the code.

## Rapidly Updating Environment Values

Every update to an environment key incurs a cost for EVERY VIEW that reads ANY KEY, even ones that aren't being updated, from the environment in the affected subtree, as SwiftUI must check whether each view's value has changed. Avoid placing values that change at high frequency (scroll offset, window size, drag position) into the environment.

Common high-frequency sources to watch for when reviewing client code — if any of these flow into an `@Entry` value or `.environment(\.key, value)` modifier, treat it as this anti-pattern:

- Scroll offset from `scrollPosition` / `onScrollGeometryChange`
- Window or container size from `GeometryReader` / `onGeometryChange`
- Drag translation or current location from `DragGesture().onChanged`
- Per-frame animation progress (`TimelineView`, `CADisplayLink`-driven values)
- Timer-driven state (`.timer` publisher, `Timer`)
- Pointer / cursor / hover location

Instead, store frequently updated values in an `@Observable` model. `@Observable` tracks per-property access, so only views that read a specific property invalidate when it changes. Prefer coarsened boolean thresholds over point-precise values: a view that reads `isWide` only invalidates when crossing the boundary, not on every pixel of a resize.

```swift
// AVOID: Propagating a rapidly-changing CGFloat through the environment.
// Every pixel of a window resize incurs a comparison cost for all
// environment-reading views in the subtree.
extension EnvironmentValues {
    @Entry var windowWidth: CGFloat = 0
}

struct RootView: View {
    var body: some View {
        GeometryReader { proxy in
            ContentView()
                .environment(\.windowWidth, proxy.size.width)
        }
    }
}

struct ContentView: View {
    @Environment(\.windowWidth) private var width

    var body: some View {
        Text(width > 600 ? "Wide layout" : "Compact layout")
    }
}
```

```swift
// PREFER: Hold geometry in an @Observable model and expose coarsened
// thresholds. Views only invalidate when crossing a meaningful
// boundary, not on every pixel.
@MainActor
@Observable
final class ViewportModel {
    var width: CGFloat = 0 {
        didSet { isWide = width > 600 }
    }

    private(set) var isWide: Bool = false
}

struct RootView: View {
    @State private var viewport = ViewportModel()

    var body: some View {
        ContentView()
            .environment(viewport)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                viewport.width = newWidth
            }
    }
}

struct ContentView: View {
    @Environment(ViewportModel.self) private var viewport

    var body: some View {
        // Only invalidates when isWide flips, not on every pixel.
        Text(viewport.isWide ? "Wide layout" : "Compact layout")
    }
}
```

The same shape applies to per-item coarsening in lists. When each row's appearance depends on scroll position, the naive fix (store the offset on an `@Observable` model and have rows read it raw) does not actually reduce invalidations. Each row still depends on `offset`, so SwiftUI invalidates all visible rows on every frame, just routed through the model instead of the environment. The work to do is **at the model**: give each item its own `@Observable` object whose properties track only that item's derived state. Because Observation tracks at the property level, a row that reads `itemModel.isVisible` invalidates only when *that specific property* changes, not when a sibling's property changes. This achieves true per-item isolation: each row invalidates at most twice (once on enter, once on leave), regardless of list size or scroll speed.

```swift
// AVOID: Migrating to @Observable but rows still read the raw offset.
// `FeedItemView` invalidates on every scroll frame just like before —
// the cost moved from environment propagation to observation tracking,
// but the per-frame body invalidation count is unchanged.
@MainActor
@Observable
final class FeedModel {
    var offset: CGFloat = 0
}

struct FeedItemView: View {
    let index: Int
    @Environment(FeedModel.self) private var feed

    var body: some View {
        Text("Item \(index)")
            .opacity(feed.offset > CGFloat(index * -50) ? 1 : 0.3)  // reads raw offset
    }
}
```

```swift
// PREFER: Per-item @Observable model. Each row observes only its own
// `isVisible` property, so it invalidates at most twice (enter + leave)
// regardless of how many other items change visibility.
@MainActor
@Observable
final class FeedModel {
    private(set) var items: [ItemModel] = []

    func updateOffset(_ offset: CGFloat) {
        let visible = Set(computeVisibleIndices(for: offset))
        for (i, item) in items.enumerated() {
            item.isVisible = visible.contains(i)
        }
    }

    private func computeVisibleIndices(for offset: CGFloat) -> [Int] {
        // ... derive visible indices from offset, item height, viewport height.
    }
}

@MainActor
@Observable
final class ItemModel {
    let index: Int
    var isVisible = false
    init(index: Int) { self.index = index }
}

struct FeedItemView: View {
    @Environment(ItemModel.self) private var item

    var body: some View {
        Text("Item \(item.index)")
            .opacity(item.isVisible ? 1 : 0.3)
    }
}

// Parent wiring: inject a different ItemModel per row.
struct FeedView: View {
    @State private var feedModel = FeedModel()

    var body: some View {
        ScrollView {
            LazyVStack {
                ForEach(feedModel.items) { item in
                    FeedItemView()
                        .environment(item)
                }
            }
        }
    }
}
```

A common intermediate step is storing a shared `Set<Int>` of visible indices on the model and having each row call `.contains(index)`. This fires only on boundary crosses (not every frame), so it is a real improvement over the raw-offset approach. However, Observation tracks at the property level: mutating the set invalidates *every* row that read it, not just the 1-2 rows whose visibility actually changed. The per-item model above achieves true O(1) invalidation per visibility change.

The discriminating question is *"what's the granularity of the value the view actually reads?"* — not "is the value held in `@Observable`?" `@Observable` is a precondition for per-property tracking; coarsening is what reduces the per-frame body-invalidation count.

A note on framework alternatives: for purely visual effects driven by scroll position (opacity, scale, rotation tied to position in the viewport), `scrollTransition` and `visualEffect(in:)` push the per-frame work to the renderer and skip body re-evaluation entirely. They are the right tool when nothing outside the row's visual styling depends on the scroll position. They do not replace the `@Observable` + coarsening pattern when the scroll-derived state needs to drive *non-rendering* logic (model updates, prefetches, network calls, sibling-view state). When in doubt: if you'd otherwise propagate the value via `@State` / `@Environment` to drive logic, use the coarsened model; if you only need a view modifier, use the framework modifier.

## Unstable Environment Default Values

An environment key's `defaultValue` is re-evaluated on every read that falls back to it whenever it's declared as a computed property. Two common ways to hit this:

- `@Entry` always wraps the default expression in a computed getter (for concurrency safety — the default doesn't need to be `Sendable`). So `@Entry var model = Model()` re-allocates `Model()` on every fallback read.
- A manual `EnvironmentKey` with a computed default — `static var defaultValue: T { Model() }` — re-runs the expression on every access for the same reason.

Either shape is a problem for **all reference types** (each call allocates a new heap instance, so reference equality fails) and more generally for **any default expression that can return a different result between calls**, even value types like `Date()`, `UUID()`, or random numbers.

Any ancestor write to *any* environment key causes descendants to re-read theirs. A reader that falls back to an unstable default gets a different value than before and invalidates, even though nothing relevant to it changed.

`Equatable` is a fast path, not a prerequisite. Even without `Equatable` conformance, SwiftUI treats two instances with matching fields as equal. This means a value-typed default is stable as long as each stored property resolves to the same value on every call — enum cases, `nil`, fixed literals, and references that point to the same instance across calls all qualify. What breaks stability is any stored property that differs between calls: a fresh reference allocation (`struct Foo { let model = Model() }` — each `Foo()` creates a new `Model`, so two `Foo` instances' `model` fields are different pointers) or a captured runtime value (`Date()`, `UUID()`). The operative test is "does the expression return a different result between calls," not "does the type conform to `Equatable`." (Closures are governed by the separate closures-in-env rule earlier in this section — that rule forbids them outright, regardless of whether they appear at a default or a write site.)

Stable defaults don't hit this: a fixed literal, a `nil` optional default, or a `let`-backed value (either an `@Entry` backed by a `static let`, or a manual key with `static let defaultValue`) all return the same value on every read.

The invalidation only materializes when a reader actually falls back to the default. If every reader has a value injected upstream via `.environment(\.key, …)`, the unstable default is latent — fixing it is still correct (a future maintainer adding a reader without upstream injection, or removing an existing injection, would silently surface the problem), but it's a regression guard rather than a current-cost recovery. When reviewing, distinguish the two: a live issue has readers falling back and paying invalidation now; a latent one has every reader currently covered by an upstream injection. The fix shape is identical either way, but framing — urgency, priority, how you describe it in a PR — isn't.

### EXAMPLE: @Entry with an unstable default

```swift
@Observable class Model {}

extension EnvironmentValues {
    @Entry var model = Model()
    @Entry var counter = 0
}

struct ContentView: View {
    @State private var counter = 0

    var body: some View {
        VStack {
            Button("++") { counter += 1 }
            RowContent()
        }
        .environment(\.counter, counter)
    }
}

struct RowContent: View {
    @Environment(\.model) private var model

    var body: some View {
        // Every "++" invalidates this view because `model`'s default
        // getter constructs a new `Model()` on every read.
        let _ = Self._printChanges()
        Text("Row Content")
    }
}
```

A value-typed re-evaluating default has the same problem — `@Entry var lastRefreshed = Date()` produces a different timestamp on each read, and readers invalidate on every unrelated env update for the same reason.

### Not a fix: Conforming the default type to Equatable

Making the unstable type conform to `Equatable` with a trivial or degenerate `==` can suppress the invalidation symptom, but the default expression still re-evaluates on every read. A new instance is allocated each time, any side effects in the initializer still fire, and two readers that fall back to the default get different instances — so observation changes on one don't propagate to the other.

```swift
// AVOID: Equatable masks invalidation without fixing the underlying re-evaluation.
@Observable final class Model: Equatable {
    init() { print("init") }  // still fires on every unrelated env write
    var id = 0
    static func == (lhs: Model, rhs: Model) -> Bool { lhs.id == rhs.id }
}

extension EnvironmentValues {
    @Entry var model = Model()
}
```

Use Options A, B, or C below so the default itself is stable.

### Not a fix: Defensive memoization of already-stable defaults

If the default satisfies the operative test above — every field resolves to the same value across calls (literals, `nil`, module-level `let` references, including struct fields that capture a module-level `let`) — leave it alone. Don't recommend `static let` backing, an `Optional` wrap, or a "regression guard" rewrite "for clarity." Don't recommend adding `Equatable` conformance "for safety" either — the default is already byte-equal on every call without it (`Equatable` is a fast path, not a prerequisite), and the prior "Not a fix: Conforming the default type to Equatable" section explains why `Equatable` doesn't fix unstable defaults anyway. A defensive refactor is noise that implies a bug where there isn't one and adds an indirection without changing behavior. Apply Options A/B/C only when the operative test actually fails.

Reviewers commonly misfire on two shapes — call them out specifically and leave them alone:

- **A struct field holds a reference, but the reference comes from a stable source.** A class type in the struct is *not* a red flag on its own. What matters is whether the source of the reference is stable. A module-level `let`, a `static let`, or a dependency-injected instance held by the caller all produce the same pointer on every call to the default expression.
- **A struct constructed inline in `@Entry` with deterministic argument values.** Enum cases with no associated values, `nil`, literals, and the stable references above all qualify. The struct itself doesn't need to be `Equatable` — SwiftUI compares field-by-field.

```swift
// FINE: stable default — do not "fix" this.
// `sharedLogger` is a module-level `let`, so every call to
// `RequestContext(logger: sharedLogger, retryBudget: 3)` captures
// the same `Logger` pointer; `retryBudget: 3` is a literal.
// Two default-evaluated `RequestContext` instances are byte-equal,
// regardless of whether `RequestContext` conforms to `Equatable`.

final class Logger { func log(_ message: String) {} }

struct RequestContext {
    let logger: Logger
    let retryBudget: Int
}

private let sharedLogger = Logger()

extension EnvironmentValues {
    @Entry var requestContext = RequestContext(logger: sharedLogger, retryBudget: 3)
}
```

```swift
// FINE: stable default — do not "fix" this.
// `.standard` is an enum case with no associated values and `nil`
// for `PresentationHandler?` is a constant. Two `ViewContext(mode: .standard, presentation: nil)`
// calls produce byte-equal instances. `Equatable` conformance is
// not required for SwiftUI to dedupe them.

protocol PresentationHandler { func dismiss() }

struct ViewContext {
    enum Mode { case standard, compact, expanded }
    let mode: Mode
    let presentation: PresentationHandler?
}

extension EnvironmentValues {
    @Entry var viewContext = ViewContext(mode: .standard, presentation: nil)
}
```

Contrast with the unstable shape — same struct skeleton, but the default expression *constructs* a fresh reference on every call:

```swift
// AVOID: unstable default. `RequestContext()` runs the `logger = Logger()`
// default initializer on every fallback read, so two default-evaluated
// instances carry different `logger` pointers.

struct RequestContext {
    let logger = Logger()      // fresh allocation per init
    let retryBudget = 3
}

extension EnvironmentValues {
    @Entry var requestContext = RequestContext()
}
```

The discriminating question is always *"does this default expression return a different result between calls?"* — not "does this struct contain a class?" and not "is this type `Equatable`?"

### FIX: Unstable environment default values

These options apply to both the reference-type case and any fresh-value case (`Date()`, `UUID()`, etc.) — substitute the unstable expression as needed.

**Option A: Back the default with a stable property**

Declare a `static let` next to the `@Entry` declaration and reference it from the initializer. The macro still wraps the expression in a computed getter, but the expression now resolves to the same memoized value on every read.

```swift
@Observable class Model {}

extension EnvironmentValues {
    @Entry var model = _defaultModel
    private static let _defaultModel = Model()
    @Entry var counter = 0
}

struct ContentView: View {
    @State private var counter = 0

    var body: some View {
        VStack {
            Button("++") { counter += 1 }
            RowContent()
        }
        .environment(\.counter, counter)
    }
}

struct RowContent: View {
    @Environment(\.model) private var model

    var body: some View {
        // `_defaultModel` is a `static let`, so every read returns the
        // same instance. Updating `\.counter` no longer invalidates.
        let _ = Self._printChanges()
        Text("Row Content")
    }
}
```

**Option B: Declare the `EnvironmentKey` manually**

Skip `@Entry` for this key and write the conformance by hand. Use `static let defaultValue` — a stored constant, evaluated once and memoized. Do not use `static var defaultValue: T { … }`; a computed property re-evaluates on every read, giving you the same problem the macro has.

```swift
private struct ModelKey: EnvironmentKey {
    static let defaultValue = Model()
}

extension EnvironmentValues {
    var model: Model {
        get { self[ModelKey.self] }
        set { self[ModelKey.self] = newValue }
    }
}
```

`ContentView` and `RowContent` are unchanged from Option A.

**Option C: Use an optional with a `nil` default**

An `@Entry` with an `Optional` type and no initializer defaults to `nil` — a constant. Callers must handle the optional, but the default is stable across every read.

```swift
extension EnvironmentValues {
    @Entry var model: Model?
}
```

`ContentView` and `RowContent` are unchanged from Option A; `model` is now an optional at call sites.

**Diagnostic — sentinel values in readers signal Option C.** When you flag an unstable default, look at what readers do with the value. If a reader checks for an "empty" or "default" state with something like `value.id.isEmpty`, `value.count == 0`, `value == .none`, `value === sentinelInstance`, or compares against the same default the `@Entry` constructs — that check *is* an absence test in disguise. The reader is encoding "no value here" as a magic value. The honest expression of that intent is `Optional` + `if let`, not a sentinel field on a real instance. Picking Option A or B in this case fixes the invalidation but leaves a worse design in place: the sentinel survives, every caller has to know the magic value, and the type system can't tell you when you forgot to check. Pick Option C and update readers to branch on the optional.

```swift
// Before: unstable default, sentinel-as-absence in reader.
@Observable final class EditingSession {
    var documentId: String
    init(documentId: String) { self.documentId = documentId }
}

extension EnvironmentValues {
    @Entry var editingSession = EditingSession(documentId: "")  // unstable + sentinel default
}

struct DocumentArea: View {
    @Environment(\.editingSession) private var session
    var body: some View {
        if session.documentId.isEmpty {            // sentinel-as-absence
            Text("No document open")
        } else {
            Text("Editing: \(session.documentId)")
        }
    }
}

// After: Option C — absence becomes an Optional, sentinel disappears.
extension EnvironmentValues {
    @Entry var editingSession: EditingSession?
}

struct DocumentArea: View {
    @Environment(\.editingSession) private var session
    var body: some View {
        if let session {                            // honest absence test
            Text("Editing: \(session.documentId)")
        } else {
            Text("No document open")
        }
    }
}
```

**Choosing between A, B, and C:** Run the diagnostic above first. If readers contain a sentinel check, pick **Option C** and rewrite the readers to use `if let` — fixing the unstable default *and* removing the sentinel design. If readers always use the value as a real instance (no absence checks, no comparisons against magic defaults), the default itself is semantically a real value — pick **Option A** when you want to keep `@Entry` syntax and the default expression is short, or **Option B** when the manual `EnvironmentKey` pattern reads more clearly (typically when the default is complex, used from multiple places, or benefits from living on the key type rather than inline on the `@Entry` declaration). Don't list A/B/C as parallel choices and leave the pick to the reader — make the call based on what the readers actually do.

## Unused @Environment Reads

Declaring `@Environment(\.someKey)` on a view subscribes that view to changes in `\.someKey`, even if the view's `body` never references the wrapped value. When `\.someKey` changes, SwiftUI re-evaluates the view — and when the body doesn't depend on the key, that re-evaluation is pure overhead. The same applies to `@FocusedValue`.

The type-based form `@Environment(Model.self)` — used with `@Observable` models — behaves differently. Observation tracks reads at the **property** level, so declaring `@Environment(Model.self) var model` without reading any property of `model` in the body registers no property-level dependency; changes to `model`'s properties don't re-evaluate the view. An unused type-form declaration carries no live invalidation cost unless the env entry for that model has an unstable default (in which case the unstable-default section above is what applies, not a read-site problem).

When reviewing, walk each view's `@Environment` / `@FocusedValue` declarations and check whether the wrapped property is referenced in the body (directly, via the `_propertyName` projected form, or through any computed property or method the body calls). If nothing references it, delete the declaration:

- **KeyPath form (`@Environment(\.key)`, `@FocusedValue(\.key)`)**: removing is an active perf fix. Every ancestor write to `\.key` is currently invalidating the view.
- **Type form (`@Environment(Model.self)`)**: removing is dead-code cleanup. There's no live invalidation cost unless the underlying env has an unstable default.

```swift
// AVOID: declared but never read in body
struct BadgeView: View {
    @Environment(\.theme) private var theme   // never referenced below
    let label: String

    var body: some View {
        Text(label)
    }
}
```

```swift
// PREFER: remove the unused subscription
struct BadgeView: View {
    let label: String

    var body: some View {
        Text(label)
    }
}
```
