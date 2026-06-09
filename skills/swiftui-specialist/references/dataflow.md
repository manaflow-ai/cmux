# Data Flow

How data flows through a SwiftUI app determines which views invalidate and when. `@State` owns view-local state. `@Observable` model objects carry data that's shared across a subtree, with per-property tracking that scopes invalidation to the exact views that read what changed. `Binding` lets a child edit state owned by a parent. The sections below cover what shape of data to hand each view, when to use each ownership tool, how to set up models so views invalidate as narrowly as possible, and how to handle side effects and two-way edits.

## Passing data into views

A view's input shape determines its invalidation surface for value-type inputs. SwiftUI compares value types field by field; if any field changed, the view's body runs. A view declared with `let user: User` (a struct) invalidates whenever any property of `User` is replaced — even properties this view never reads. A view declared with `let name: String` invalidates only when the name changes.

Reference types behave differently. SwiftUI compares class instances by pointer identity, not field by field — a view that holds a class reference re-invalidates only when the parent hands it a different instance. For `@Observable` class models, the observation system layers on top of that: it tracks which properties each view reads during `body` and invalidates only the views that read the specific property that changed (see "Model objects with @Observable" below). So the narrow-inputs rule is critical for value-type inputs and largely doesn't apply to reference-type inputs.

### Pass views only the data they read

For value-type inputs, this applies to every view, not just subviews extracted from a larger parent. A top-level screen view that takes a whole struct model just to display one of its fields invalidates on every unrelated update to that struct. Take only the data the view actually uses.

```swift
// AVOID: Taking the whole `User` struct (a value type) when the view
// reads only one field. SwiftUI compares `User` field by field, so
// `AvatarBadge` invalidates on any `User` change — bio edit, follower
// count tick, preferences toggle — even though it only displays
// `avatarURL`.
struct User {
    var name: String
    var bio: String
    var avatarURL: URL
    var followerCount: Int
    // ... more fields
}

struct AvatarBadge: View {
    let user: User

    var body: some View {
        AsyncImage(url: user.avatarURL)
    }
}
```

```swift
// PREFER: Take only the field the view actually reads.
struct AvatarBadge: View {
    let avatarURL: URL

    var body: some View {
        AsyncImage(url: avatarURL)
    }
}
```

"Reads" includes "forwards to a subview." A view that takes `let avatarURL: URL` and passes it to `AvatarBadge(avatarURL: avatarURL)` is using `avatarURL` — even though it never appears in a `Text(...)` or modifier directly. Forwarding a field to a child is a use of that field. The rule targets fields a view *truly* never touches (an unread sibling field of a struct input), not fields the view consumes by constructing children that render them. A parent that takes five fields and forwards each to the right subview is correctly factored, not "holding data it doesn't read."

### Watch the cost of large value-type inputs

The field-by-field comparison SwiftUI does for value-type inputs isn't free: every input check walks every field. For small structs (a few primitives, a URL) the cost is negligible. For a struct decoded from a large JSON payload — nested arrays, dictionaries, dozens of fields — it adds up. Every body evaluation in the parent does a deep comparison over the entire payload to decide whether the child changed, and every subview that takes the payload as an input pays the same cost.

The "narrow inputs" rule above already mitigates this — a subview that takes `let title: String` does one string comparison, not a tree walk over a decoded response.

```swift
// AVOID: Passing a large value-type payload through the view tree.
// Every parent body evaluation deep-compares the entire struct against
// the previous value just to decide whether the row changed, and every
// subview that takes it as input pays the same cost.
struct Article {
    let id: UUID
    let title: String
    let author: String
    let body: String                  // can be 50KB+
    let comments: [Comment]           // can be hundreds
    let related: [RelatedArticle]
    let editorialNotes: [Note]
    // ... many more fields
}

struct ArticleRow: View {
    let article: Article

    var body: some View {
        Text(article.title)
    }
}
```

```swift
// PREFER: The full payload doesn't live on any view. It's owned by the
// model layer (decoded once into an `@Observable`, or broken into
// smaller per-view structs), and views see only the narrow values they
// render. Nothing in the view tree pays a deep-comparison cost over
// `body`, `comments`, or `related`.
struct ArticleRow: View {
    let title: String

    var body: some View {
        Text(title)
    }
}
```

#### Break the payload into per-view structs

When every field of a large struct really is consumed across the view tree, the answer is not "pass it whole anyway." Break the payload into discrete structs that each belong to a specific view, so each view's comparison surface is bounded by what that view actually displays. Don't make the app's entire value-type data model the input to every view in the hierarchy.

#### Or hold the payload in an @Observable model

If you don't want to split a large value type into smaller ones — typically because the type maps cleanly to a server payload and reshaping it would ripple through decoding — put it inside an `@Observable` model and pass the model instead. Reference comparison is cheap (pointer identity), and the observation system invalidates only views that read individually-tracked properties. But take care with compound stored properties on the model: a view that reads an entire `Array`, `Dictionary`, or `Set` establishes a dependency on the *whole collection*, so any element change invalidates that view. See "Per-property dependency granularity on @Observable models" below for the mitigation — cache derived values or extract a smaller `@Observable` model and hand each view that.

## View-local state with @State

- Always mark `@State` properties as `private`. If you encounter a `@State` variable that already has an access control specified, recommend changing it to `private`, but don't change it (to avoid breaking the build), unless you are instructed to do that.

## Model objects with @Observable

Use `@Observable` (not `ObservableObject`) for classes that provide data to views. The macro generates per-property observation tracking that scopes invalidation to the exact views that read the changed property — far cheaper than `ObservableObject`'s coarse `objectWillChange` broadcasts.

Mark `@Observable` classes with `@MainActor` unless the project has Main Actor default actor isolation (typically set via `SWIFT_DEFAULT_ACTOR_ISOLATION` in the build settings). Views read the model on the main actor during body evaluation; without `@MainActor` the model's properties are reachable from any thread, and writes from background tasks can race with view reads. Swift 6 strict concurrency flags this.

`@Observable` is not supported on `actor` types.

```swift
// AVOID: @Observable class without @MainActor. Properties are reachable
// from any thread, but views read them on the main actor — background
// writes can race with main-actor reads, and strict concurrency will
// flag the model.
@Observable
final class OrderModel {
    var status: DeliveryStatus = .placed
}
```

```swift
// PREFER: @MainActor on the @Observable class. Reads and writes are
// confined to the main actor, matching how views consume the model.
// Background work that produces a new value hops to the main actor
// (e.g. `await MainActor.run { model.status = .shipped }`).
@MainActor
@Observable
final class OrderModel {
    var status: DeliveryStatus = .placed
}
```

### Make @Observable property types Equatable

Prefer making the types of stored properties in `@Observable` model objects conform to `Equatable`. The `@Observable` macro generates a setter that skips invalidation when the new value equals the current one — but only when it can compare them, which means only when the type is `Equatable`. Without that conformance, every set notifies, even when the new value is identical. This is an easy performance win for properties that are written frequently with the same value (e.g. from polling, streaming updates, or timers).

This applies to all OS releases that support `@Observable` (iOS 17 / macOS 14 and aligned) when built with current Xcode — the equality check is emitted into the generated setter as user code, not delegated to a runtime feature.

```swift
// AVOID: DeliveryStatus is not Equatable.
// Every assignment to `status` invalidates observing views, even if the
// value hasn't actually changed.
enum DeliveryStatus {
    case placed, preparing, shipped, delivered
}

@MainActor
@Observable
final class OrderModel {
    var status: DeliveryStatus = .placed
}
```

```swift
// PREFER: Making DeliveryStatus Equatable lets the @Observable setter
// short-circuit redundant invalidations when the same status is set
// again.
enum DeliveryStatus: Equatable {
    case placed, preparing, shipped, delivered
}

@MainActor
@Observable
final class OrderModel {
    var status: DeliveryStatus = .placed
}
```

The same principle applies to collection properties. When a property is an `Array` (or `Set`, `Dictionary`, etc.), the collection's `Equatable` conformance delegates to its elements. If the element type is not `Equatable`, the collection isn't either, so every assignment to the collection triggers invalidation even when the contents are identical.

```swift
// AVOID: Ingredient is not Equatable, so assigning the same array of
// ingredients to `recipe.ingredients` always invalidates observing views.
struct Ingredient {
    var name: String
    var quantity: Double
    var unit: String
}

@MainActor
@Observable
final class RecipeModel {
    var ingredients: [Ingredient] = []
}
```

```swift
// PREFER: Making Ingredient Equatable allows Array's built-in Equatable
// conformance to compare element-wise, so the @Observable setter skips
// redundant invalidations when the same ingredients are set again.
struct Ingredient: Equatable, Identifiable {
    var name: String
    var quantity: Double
    var unit: String
}

@MainActor
@Observable
final class RecipeModel {
    var ingredients: [Ingredient] = []
}
```

### Per-property dependency granularity on @Observable models

When a view reads a property of an `@Observable` model, the observation system records a dependency on that exact property and invalidates the view only when *that* property changes. So a view that reads `model.title` invalidates on `title` changes but not on `model.description` changes — this per-property tracking is the main reason `@Observable` is so much cheaper than `ObservableObject` for granular updates.

The subtlety is that "property" is the granularity, not "field within a property". A property whose type is itself compound — a struct, an `Array`, a `Dictionary`, a `Set` — creates a dependency on the *entire value*. Reading any field of a stored struct, or any element of a stored collection, establishes a dependency on the whole stored property. The subsections below cover the common shapes of this trap.

Computed properties still establish dependencies transitively: a computed `var selectedItem: Item? { items.first { $0.id == selectedID } }` reads `items` inside its body, so any view that reads `model.selectedItem` ends up with a dependency on `items`. Renaming the access doesn't change what observation tracks. The fix is to cache the derived value as its own stored property and keep it in sync.

### Cache derived @Observable values; computed properties still establish dependencies transitively

```swift
// AVOID: A view that needs only one item, but reaches it through the
// whole collection. Every change to `users` — add, remove, edit any
// field of any user — invalidates `CurrentUserBadge`.
@MainActor
@Observable
final class AppState {
    var users: [User] = []
    var currentUserID: User.ID?
}

struct CurrentUserBadge: View {
    let state: AppState

    var body: some View {
        if let id = state.currentUserID,
           let user = state.users.first(where: { $0.id == id }) {
            Text(user.name)
        }
    }
}
```

```swift
// AVOID (attempted fix that doesn't work): Wrapping the lookup in a
// computed property *looks* like it narrows the dependency, but the
// computed body reads `users` — so `state.currentUser` establishes a
// dependency on the whole array transitively. Renaming the access
// doesn't change what observation tracks.
@MainActor
@Observable
final class AppState {
    var users: [User] = []
    var currentUserID: User.ID?

    var currentUser: User? {
        users.first { $0.id == currentUserID }
    }
}

struct CurrentUserBadge: View {
    let state: AppState

    var body: some View {
        if let user = state.currentUser {
            Text(user.name)
        }
    }
}
```

```swift
// PREFER: Cache the derived value as its own stored property and keep
// it up to date in didSet. Views read the prepared property and
// invalidate only when *it* changes — not on every change to `users`.
@MainActor
@Observable
final class AppState {
    var users: [User] = [] {
        didSet { recomputeCurrentUser() }
    }
    var currentUserID: User.ID? {
        didSet { recomputeCurrentUser() }
    }

    private(set) var currentUser: User?

    private func recomputeCurrentUser() {
        currentUser = users.first { $0.id == currentUserID }
    }
}

struct CurrentUserBadge: View {
    let state: AppState

    var body: some View {
        if let user = state.currentUser {
            Text(user.name)
        }
    }
}
```

### Extract a smaller @Observable when many views share data

When a piece of data is read by many independent views — or by views that should be invalidation-isolated from each other — pull it into its own `@Observable` model and hand each view that smaller model rather than the larger one. The view's dependency surface is then bounded by the smaller model, and the larger model can change without rippling through.

### Multiple individual @Observable property reads are fine

A view that reads several individual properties from one `@Observable` model is **not** over-subscribed and doesn't need to be split. Per-property tracking already scopes the view's invalidation to exactly those properties; carving the model into per-property subviews adds indirection without changing what re-runs when. The granularity traps in this file are about *single* reads that pull in too much — a struct-typed field that drags the whole struct, an array access that drags the whole collection, a computed property that proxies the same wide read. They are not about views that legitimately read several already-narrow properties.

### Pass @Observable collection elements directly to row views

When iterating a collection from an `@Observable` model, the list view that holds the `ForEach` legitimately depends on the collection — it needs to re-run when elements are inserted, removed, or reordered. The row view shouldn't reach back into the model to look up its element by index or key, though: doing so makes every row depend on the whole collection, so editing one user invalidates every row. Pass the element value directly into the row.

#### Single-field rows: pass the field

```swift
// AVOID: Row reaches back into the model by index. Every UserRow's
// body reads `state.users`, so any edit to any user invalidates every
// row — not just the one whose data changed.
struct UserList: View {
    let state: AppState

    var body: some View {
        ForEach(state.users.indices, id: \.self) { index in
            UserRow(state: state, index: index)
        }
    }
}

struct UserRow: View {
    let state: AppState
    let index: Int

    var body: some View {
        Text(state.users[index].name)
    }
}
```

```swift
// PREFER: Pass the row only the field it displays. `UserList` depends
// on `state.users` (correct — the list shape depends on it), but each
// `UserRow` takes just the name it renders. Editing one user's email
// doesn't re-run any row's body; editing one user's name re-runs only
// that row.
struct UserList: View {
    let state: AppState

    var body: some View {
        ForEach(state.users) { user in
            UserRow(name: user.name)
        }
    }
}

struct UserRow: View {
    let name: String

    var body: some View {
        Text(name)
    }
}
```

#### Multi-field rows: pass a persisted @Observable instance

An alternative pattern, useful when each row genuinely observes several fields of its element: model each element as its own `@Observable` and have the parent **persist** the instances. The list view still depends on the array of references (so it re-runs on inserts, removes, and reorders), but each row's dependencies are scoped to its own model — a row can observe multiple properties of its user without depending on the whole collection or the whole struct, and editing one field of one user invalidates only the row that displays that user.

The instances must be persisted. Vending a freshly-constructed `@Observable` on every read hands each row a new reference on every parent body evaluation; stored references compare unequal each time, every row's body re-runs, and nothing has actually changed.

```swift
// PREFER (multi-field rows): Per-element @Observable models that the
// parent stores and reuses. `UserRow` observes its specific user
// directly, so editing one field of one user invalidates only that
// row — and the row gets to read multiple fields without paying the
// whole-collection cost.
@MainActor
@Observable
final class User: Identifiable {
    let id: UUID
    var name: String
    var email: String
    var avatarURL: URL

    init(id: UUID = UUID(), name: String, email: String, avatarURL: URL) {
        self.id = id
        self.name = name
        self.email = email
        self.avatarURL = avatarURL
    }
}

@MainActor
@Observable
final class AppState {
    var users: [User] = []  // persisted; each User's identity is stable
    // ... mutations modify existing User instances in place
}

struct UserList: View {
    let state: AppState

    var body: some View {
        ForEach(state.users) { user in
            UserRow(user: user)
        }
    }
}

struct UserRow: View {
    let user: User

    var body: some View {
        HStack {
            AsyncImage(url: user.avatarURL)
                .frame(width: 32, height: 32)
                .clipShape(Circle())
            VStack(alignment: .leading) {
                Text(user.name).font(.headline)
                Text(user.email).font(.caption)
            }
        }
    }
}
```

### Expose struct fields as individual @Observable properties

When an `@Observable` model holds a value-type struct as a stored property, the observation system tracks reads at the *property* level — not at the struct's fields. A view that reads `session.user.name` depends on `session.user`. Mutating any field of `user` — or replacing it with a new `User` value — invalidates every view that touched it, even views that only displayed `name`.

The fix is to expose the struct's fields as individual properties on the `@Observable` model. The observation system tracks each field separately, and a view that reads only `userName` invalidates only when `userName` changes.

```swift
// AVOID: User struct held as a single property on the @Observable
// model. `ProfileBadge` reads `session.user.name`, `session.user.email`,
// `session.user.avatarURL` — every one of those reads establishes a
// dependency on `session.user`. Editing `preferences` (or any other
// field of `user`) also invalidates the view.
struct User {
    var name: String
    var email: String
    var avatarURL: URL
    var preferences: Preferences
}

@MainActor
@Observable
final class UserSession {
    var user: User

    init(user: User) { self.user = user }
}

struct ProfileBadge: View {
    let session: UserSession

    var body: some View {
        HStack {
            AsyncImage(url: session.user.avatarURL)
                .frame(width: 32, height: 32)
                .clipShape(Circle())
            VStack(alignment: .leading) {
                Text(session.user.name).font(.headline)
                Text(session.user.email).font(.caption)
            }
        }
    }
}
```

```swift
// PREFER: Flatten the struct's fields onto the model. Each field is
// tracked independently. `ProfileBadge` depends on `userName`,
// `userEmail`, and `avatarURL` — not on `preferences` — so editing
// preferences no longer invalidates it.
@MainActor
@Observable
final class UserSession {
    var userName: String
    var userEmail: String
    var avatarURL: URL
    var preferences: Preferences

    init(user: User) {
        self.userName = user.name
        self.userEmail = user.email
        self.avatarURL = user.avatarURL
        self.preferences = user.preferences
    }
}

struct ProfileBadge: View {
    let session: UserSession

    var body: some View {
        HStack {
            AsyncImage(url: session.avatarURL)
                .frame(width: 32, height: 32)
                .clipShape(Circle())
            VStack(alignment: .leading) {
                Text(session.userName).font(.headline)
                Text(session.userEmail).font(.caption)
            }
        }
    }
}
```

If the struct needs to be round-tripped (re-encoded into a payload, sent back to a server) and you don't want to lose its shape, keep both: a `var user: User` for round-tripping and individual properties for view consumption, kept in sync via `didSet` on `user`.

## Side effects in views

### Isolating onChange(of:) side-effect invalidation

When a view uses `.onChange(of:)` to react to a dependency (an `@Environment` value, a `@Binding`, or a property from an `@Observable` object), that dependency is read in the view's body scope. This creates a dependency on that value: the view's body is re-evaluated every time the dependency changes, even if the dependency is not used for rendering.

If the view's body is expensive (deep hierarchy, many children), this causes unnecessary work. Extract the `.onChange` and the dependency it observes into a separate view dedicated to handling that side effect. This way only the lightweight side-effect view is re-evaluated when the value changes.

```swift
// AVOID: ContentView reads `counter` from the environment solely for
// .onChange. Every change to `counter` creates a dependency and
// re-evaluates the expensive ScrollView hierarchy.
struct ContentView: View {
    @State private var model = Model()
    @Environment(\.counter) private var counter

    var body: some View {
        ScrollView {
            // ... expensive view hierarchy ...
        }
        .onChange(of: counter) {
            model.counter = counter
        }
    }
}
```

```swift
// PREFER: Extract the dependency and .onChange into a ViewModifier.
// The modifier owns the read of `counter` — when counter changes, only
// the modifier's body re-runs, not ContentView's. The host view's
// dependency surface doesn't include `counter` at all.
struct CounterSyncModifier: ViewModifier {
    let model: Model
    @Environment(\.counter) private var counter

    func body(content: Content) -> some View {
        content
            .onChange(of: counter) {
                model.counter = counter
            }
    }
}

extension View {
    func counterSync(model: Model) -> some View {
        modifier(CounterSyncModifier(model: model))
    }
}

struct ContentView: View {
    @State private var model = Model()

    var body: some View {
        ScrollView {
            // ... expensive view hierarchy ...
        }
        .counterSync(model: model)
    }
}
```

The same principle applies to any dependency type - `@Binding`, `@Observable` properties, or combinations:

```swift
// AVOID: EditorView reads both `document.wordCount` and `isActive`
// solely for side effects. Changes to either re-evaluate the
// expensive editor body.
struct EditorView: View {
    var document: DocumentModel
    @Binding var isActive: Bool
    @State private var model = EditorModel()

    var body: some View {
        ScrollView {
            // ... expensive text editor hierarchy ...
        }
        .onChange(of: document.wordCount) {
            model.updateStatistics(wordCount: document.wordCount)
        }
        .onChange(of: isActive) {
            model.setActive(isActive)
        }
    }
}
```

```swift
// PREFER: Extract both side effects into a single ViewModifier.
struct EditorChangesModifier: ViewModifier {
    var document: DocumentModel
    @Binding var isActive: Bool
    let model: EditorModel

    func body(content: Content) -> some View {
        content
            .onChange(of: document.wordCount) {
                model.updateStatistics(wordCount: document.wordCount)
            }
            .onChange(of: isActive) {
                model.setActive(isActive)
            }
    }
}

extension View {
    func editorChanges(
        document: DocumentModel,
        isActive: Binding<Bool>,
        model: EditorModel
    ) -> some View {
        modifier(
            EditorChangesModifier(
                document: document,
                isActive: isActive,
                model: model
            )
        )
    }
}

struct EditorView: View {
    var document: DocumentModel
    @Binding var isActive: Bool
    @State private var model = EditorModel()

    var body: some View {
        ScrollView {
            // ... expensive text editor hierarchy ...
        }
        .editorChanges(document: document, isActive: $isActive, model: model)
    }
}
```

Apply this pattern when all of these hold:
- A dependency is read only for a side effect (`.onChange`), not for rendering.
- The parent view has a non-trivial body that would be expensive to re-evaluate.

Do NOT apply this pattern when:
- The dependency is also used directly in the view's rendering output. The view will invalidate regardless, so isolation provides no benefit.
- The view body is already trivial. The overhead of an extra view is not justified.

## Bindings

### Use KeyPath bindings, not closure bindings

Always prefer to use a KeyPath-based Binding with subscripts instead of a get-set binding with a closure. Consider this model and child view:

```swift
@Observable
final class ScoreboardModel {
    private(set) var scores: [String: Int] = [
        "Alice": 42, "Bob": 17, "Carol": 99,
    ]

    let players = ["Alice", "Bob", "Carol"]

    // A subscript with a labeled argument can be used as a functional
    // 'projection' into the underlying model if given a Binding to it.
    subscript(scoreFor player: String) -> Int {
        get { scores[player, default: 0] }
        set { scores[player] = newValue }
    }
}

/// Basic view with two-way binding to a score.
struct PlayerScoreRow: View {
    var player: String
    @Binding var score: Int

    var body: some View {
        HStack {
            Text(player)
                .frame(width: 80, alignment: .leading)
            Stepper("\(score) pts", value: $score, in: 0...999)
        }
    }
}
```

Don't use a closure to produce the binding for `PlayerScoreRow`. Instead use a binding that goes through the subscript. If there is no subscript existing, you may need to create one.

```swift
/// Parent view.
struct ScoreboardView: View {
    @State private var model = ScoreboardModel()

    var body: some View {
        NavigationStack {
            List(model.players, id: \.self) { player in
                // ❌ BAD: Creating a closure means a new heap allocation each
                // time `body` is run and can result in issues with comparison,
                // triggering unnecessary invalidations.
                let badModelBinding = Binding(
                    get: { model[scoreFor: player] }
                    set: { model[scoreFor: player] = newValue }
                )
                PlayerScoreRow(player: player, score: badModelBinding)

                // ✅ GOOD: A subscript with a labeled argument can be used as a
                // functional 'projection' into the underlying model if given a
                // Binding to it.
                @Bindable var model = model
                PlayerScoreRow(player: player, score: $model[scoreFor: player])
            }
            .navigationTitle("Scoreboard")
        }
    }
}
```

# `@Entry` macro

When defining custom environment, transaction, container, or focused values, always prefer to use `@Entry` to reduce boilerplate code and avoid mistakes.

`@Entry` requires a stable default — one whose expression returns the same result on every read. See `environment.md` under "Unstable Environment Default Values" for the full rule, the unstable shapes to avoid (`Model()`, `Date()`, `UUID()`, fresh allocations, captured runtime values), and the three fix shapes (Option A: `static let` backing; Option B: manual `EnvironmentKey` with `static let defaultValue`; Option C: optional with `nil` default). The same rule applies to `@Entry` on `Transaction`, `ContainerValues`, and `FocusedValues`. Stable default shapes that don't need any of those fixes include literals (`"home"`, `0`, `true`), enum cases with no associated values (`.standard`), `nil` for an optional, and references to a stable instance (a `static let`, a module-level `let`, or a struct that captures one). When reviewing or writing an `@Entry` declaration, check the default expression against this rule before doing anything else.

Create custom environment, transaction and container values by extending the relevant structures with new properties and attaching the `@Entry` macro to the variable declarations:

```swift
extension EnvironmentValues {
    @Entry var myCustomValue: String = "Default value"
    @Entry var anotherCustomValue = true
}

extension Transaction {
    @Entry var myCustomValue: String = "Default value"
}

extension ContainerValues {
    @Entry var myCustomValue: String = "Default value"
}
```

Since the default value for `FocusedValues` is always nil, `FocusedValue`s entries cannot specify a different default value and must have an Optional type:

```swift
extension FocusedValues {
    @Entry var myCustomValue: String?
}
```

When reviewing existing code that defines custom environment, transaction, container, or focused values via manual `EnvironmentKey` / `ContainerValuesKey` / `FocusedValueKey` conformances and a `get`/`set` extension property, surface the `@Entry` refactor as a top-line review finding — not a footnote, not an "Optional Improvements" aside, not a "looks good, also consider…" tail. The manual form is older boilerplate `@Entry` was specifically designed to replace; treating the two as a stylistic toss-up is incorrect. The deployment target gates availability (`@Entry` requires iOS 18 / macOS 15 / Xcode 16); when the target isn't specified in the code under review, recommend the refactor without a defensive hedge — note availability as a one-line caveat at most. (Don't perform the rewrite unprompted during a review — show the diff or refactored snippet as the finding.)
