# ForEach

`ForEach` uses identity to match up elements across body evaluations. When SwiftUI re-runs a parent's `body`, it diffs the previous collection of identifiers against the new one to figure out which rows were inserted, removed, moved, or merely updated. The identity of each element is the anchor that lets SwiftUI:

- Preserve `@State`, focus, selection, and scroll position for a row that merely moved or whose content changed.
- Animate insertions, removals, and reorders correctly. A row keeps its on-screen presence as it moves; a new row fades or slides in; a removed row transitions out.
- Avoid rebuilding subtrees unnecessarily. Stable identity lets SwiftUI reuse the existing view for an element whose data changed rather than tearing it down and creating a fresh one.

If identity is unstable, none of this works: state resets, animations break into abrupt replacements, and performance suffers as SwiftUI rebuilds subtrees that could have been reused.

The rule of thumb: the identity of a `ForEach` element must be **stable** (the same element has the same id across body evaluations, even if its position in the collection changes) and **unique** (no two distinct elements share an id in the same `ForEach`).

## Applies to other data-driven initializers

Everything in this document applies to any SwiftUI API that takes a `RandomAccessCollection` of data plus an `id:` key path (or `Identifiable` elements) and internally behaves like `ForEach`. The most common ones:

- `List(_:id:rowContent:)` and `List(_:rowContent:)` (the `Identifiable` overload).
- `List(_:id:selection:rowContent:)` and related selection-aware overloads.
- `Table(_:)` / `Table(_:selection:)` and their `id:` overloads.
- `OutlineGroup(_:id:children:content:)` and `List(_:children:rowContent:)` (outline variants).
- `Picker` overloads that iterate a data collection, such as `Picker(_:selection:content:)` used with `ForEach` inside.
- `DisclosureGroup` when paired with `ForEach` in its content.

Whenever you see one of these taking a collection directly, read "id per element" the same way you would for `ForEach`: stable, unique, and independent of position or mutable content.

## Avoid collection indices as identity

Using a collection's indices, or `.self` on an index, as the identifier is the most common anti-pattern. Indices describe a position, not an element. As soon as the collection is reordered, inserted into, or filtered, the same index now refers to a different element - and SwiftUI has no way to tell.

```swift
// AVOID: Using indices as identity.
// When `items` is reordered or an element is inserted, every id from the
// insertion point onward now maps to a different element. SwiftUI sees
// "the element at id 3 changed" rather than "element B moved from 3 to 4",
// so row state resets and moves animate as replacements.
struct ItemList: View {
    @State private var items: [Item] = []

    var body: some View {
        List {
            ForEach(items.indices, id: \.self) { index in
                ItemRow(item: items[index])
            }
        }
    }
}
```

```swift
// PREFER: Identify each element by a property that travels with the element.
ForEach(items, id: \.id) { item in
    ItemRow(item: item)
}
```

Seeing `.indices`, `\.offset`, or `id: \.self` on anything other than a value that is genuinely identity-like (e.g. a `String` that is already a unique key) is a signal that identity is being derived from position. The fix is to identify elements by a property of the element itself.

### `.enumerated()` is fine - the index just shouldn't be the id

Using `.enumerated()` is not itself an anti-pattern. It is a reasonable way to get the index alongside each element, for example when a row needs to display its position. The anti-pattern is specifically using the index as the id. Keep the element's own identity as the id and treat the index as ordinary row data:

```swift
// AVOID: `.enumerated()` with the offset as id.
// Same failure mode as `items.indices`: the id is the position, not the element.
ForEach(items.enumerated(), id: \.offset) { index, item in
    ItemRow(number: index + 1, item: item)
}
```

```swift
// PREFER: `.enumerated()` is fine; the id comes from the element, and the
// index is just row data passed to the row view.
ForEach(items.enumerated(), id: \.element.id) { index, item in
    ItemRow(number: index + 1, item: item)
}
```

### `.enumerated()` and `RandomAccessCollection`

As of Swift 6.1, the sequence returned by `.enumerated()` conditionally conforms to `Collection`, `BidirectionalCollection`, and `RandomAccessCollection` when the base collection does. `ForEach` requires its data to be a `RandomAccessCollection`, so on Swift 6.1 and later you can pass `items.enumerated()` directly - no `Array(...)` wrapper is needed. On earlier toolchains the wrapper is still required. Favor the direct form in new code; it avoids an eager copy of the collection on every body evaluation.

## Don't create a new id on every body evaluation

An `Identifiable` type whose `id` is generated fresh each time `body` runs looks like it has identity, but every body evaluation produces a brand-new identifier. From `ForEach`'s point of view, the entire collection was replaced on every update.

```swift
// AVOID: Constructing the items inside `body`. Each call to `Item(title:)`
// initializes a new UUID, so every body evaluation produces an entirely
// new set of ids. ForEach reads it as "the whole collection was replaced":
// state resets, rows flicker, animations degenerate into full replacements.
// The `let id = UUID()` default itself is fine - the bug is creating the
// values somewhere that doesn't outlive `body`.
struct Item: Identifiable {
    let id = UUID()
    var title: String
}

struct ContentView: View {
    let titles: [String]

    var body: some View {
        List {
            ForEach(titles.map { Item(title: $0) }) { item in
                Text(item.title)
            }
        }
    }
}
```

A `let id = UUID()` default works as long as the value itself is stored somewhere durable (a `@State`, an `@Observable` model, a database row); it becomes a bug the moment the value is reconstructed on every body pass. The fix is to ensure the id is tied to something that persists across body evaluations. If the source data has a natural key (a database id, a file URL, a server-assigned id), use that. If you must synthesize an id, do it once, in storage that outlives `body` - typically the model layer.

```swift
// PREFER: Derive identity from a property that is itself immutable for
// a given element - a server-assigned id, a file URL, a catalog SKU.
// Because the property is `let`, the computed `id` can't change as the
// element is edited.
struct Document: Identifiable {
    let url: URL              // where the file lives; assigned at creation
    var displayName: String   // user-editable

    var id: URL { url }
}
```

```swift
// PREFER: Create the UUID once, in the model that owns the items, and keep
// it across updates. `body` just reads the already-stable ids.
@MainActor
@Observable
final class ItemStore {
    var items: [Item] = []

    func add(title: String) {
        items.append(Item(id: UUID(), title: title))
    }
}

struct Item: Identifiable {
    let id: UUID
    var title: String
}
```

## Prefer `Identifiable` conformance

`ForEach` accepts an explicit `id:` key path, but conforming the element type to `Identifiable` is the idiomatic choice when the element has a natural identity. It lets callers write `ForEach(items)` without repeating the key path, documents the identity at the type level, and makes the type usable with other SwiftUI APIs that expect `Identifiable` (`List`, `sheet(item:)`, `confirmationDialog(..., presenting:)`, navigation value types, etc.).

```swift
// PREFER: Identifiable conformance; the identity is declared once on the type.
struct Item: Identifiable {
    let id: UUID
    var title: String
}

ForEach(items) { item in
    ItemRow(item: item)
}
```

```swift
// Acceptable when the element type isn't yours to change, or when the id
// lives on a different type (e.g. a value type wrapping a reference).
ForEach(items, id: \.serverID) { item in
    ItemRow(item: item)
}
```

Don't conform types to `Identifiable` just to satisfy `ForEach` if there is no meaningful notion of identity for the type. In that case, pass an explicit key path to the property that acts as identity in this context.

## Keep the id cheap to hash

`ForEach` hashes and compares element ids frequently - on every diff, which happens any time the enclosing view's `body` re-evaluates the collection. If the id type is expensive to hash, that cost is paid on every update and scales with the size of the collection.

The common anti-pattern is using the entire element as the id - either `id: \.self` on a large `Hashable` struct, or an `id` property that returns the whole value. The compiler-synthesized `Hashable` conformance feeds every stored property into the hasher; for a struct that holds long strings, nested collections, or many fields, each hash does real work, and the work is repeated for every row on every update.

```swift
// AVOID: id is the whole struct. Hashing each row walks every field on every
// diff - long strings, nested arrays, the lot. Cost scales with both the
// collection size and the per-element field count.
struct Article: Hashable {
    let title: String
    let body: String        // potentially large
    let tags: [String]
    let author: Author
    let publishedAt: Date
}

ForEach(articles, id: \.self) { article in
    ArticleRow(article: article)
}
```

```swift
// PREFER: id is a small, cheap-to-hash property that uniquely identifies
// the element. The full struct is still passed to the row view; only the
// id is hashed during diffing.
struct Article: Identifiable, Hashable {
    let id: UUID
    let title: String
    let body: String
    let tags: [String]
    let author: Author
    let publishedAt: Date
}

ForEach(articles) { article in
    ArticleRow(article: article)
}
```

Good ids are small primitives: `UUID`, `Int`, a short `String` key, a `URL`. They hash in constant time independent of how large the underlying element is. If the element has a natural key (a database id, a server-assigned id, a file URL), use it; otherwise synthesize one and store it on the element.

The fix is to pick the right id, not to touch the `Hashable` conformance. Leave it as it is - it may be used elsewhere (selection, sets, dictionary keys, navigation values), and removing it is unrelated to the diffing cost.

## Identity must outlive the view that renders the `ForEach`

`ForEach` assumes that an element's identity is stable for at least as long as the view rendering the `ForEach` is on screen. If an element's id changes while the enclosing view is still alive, SwiftUI interprets it as "the old element was removed and a new one inserted", which drops the row's state and plays removal/insertion animations instead of an in-place update.

The common trap is deriving the id from a property that is mutated in place (for example, computing `id` from the current title, then editing the title). The edit changes the id, the row is destroyed and recreated mid-edit, and focus, selection, and any per-row `@State` are lost.

```swift
// AVOID: id derived from a mutable property that edits will change.
// Typing in the row's text field renames the item, which changes its id,
// which makes ForEach think the row was removed and a new one inserted.
// The text field loses focus on every keystroke.
struct Item: Identifiable {
    var id: String { title }
    var title: String
}
```

```swift
// PREFER: id is independent of any mutable content. Editing `title` leaves
// identity untouched, so the row keeps its state and focus.
struct Item: Identifiable {
    let id: UUID
    var title: String
}
```

When in doubt, ask: "If I edit this element in place, does its id change?" If yes, identity is tied to content and will break on every edit. The id should change only when the element is genuinely a different element, not when its data is updated.

## Don't sort or filter inline in `ForEach`

The collection passed to `ForEach` is evaluated every time the enclosing view's `body` runs. If that expression is a non-trivial transformation - `sorted`, `filter`, `map` that rebuilds elements, grouping, deduplication - the work is repeated on every invalidation, even ones that have nothing to do with the list contents (a parent state change, an environment update, a window resize).

```swift
// AVOID: Sorting and filtering inside the ForEach argument.
// Every body evaluation re-runs `filter` and `sorted` over the full array,
// even when the change that invalidated this view has nothing to do with
// `items` or `searchText`.
struct ItemList: View {
    let items: [Item]
    let searchText: String

    var body: some View {
        List {
            ForEach(
                items
                    .filter { $0.title.localizedCaseInsensitiveContains(searchText) }
                    .sorted { $0.title < $1.title }
            ) { item in
                ItemRow(item: item)
            }
        }
    }
}
```

Cache the derived collection on the model or in view state, and recompute it only when an input actually changes. An `@Observable` model is the natural home: recompute in a `didSet` or in the mutating entry points, and let the view read the already-sorted, already-filtered array.

```swift
// PREFER: The model owns the derived collection and updates it only when
// its inputs change. The view reads a prepared array; `body` does no work
// beyond iterating.
@MainActor
@Observable
final class ItemListModel {
    var items: [Item] = [] {
        didSet { recomputeVisibleItems() }
    }

    var searchText: String = "" {
        didSet { recomputeVisibleItems() }
    }

    private(set) var visibleItems: [Item] = []

    private func recomputeVisibleItems() {
        visibleItems = items
            .filter { $0.title.localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.title < $1.title }
    }
}

struct ItemList: View {
    let model: ItemListModel

    var body: some View {
        List {
            ForEach(model.visibleItems) { item in
                ItemRow(item: item)
            }
        }
    }
}
```

If the derived collection is genuinely view-local (e.g. a local filter box that doesn't belong in the model), cache it in `@State` and update it when inputs change via `onChange(of:)` rather than recomputing in `body`. The principle is the same: compute once per input change, not once per body evaluation.

Cheap transformations - a small slice, `prefix(n)`, reading an already-prepared array, a trivial map to a struct - are fine inline. The rule targets work whose cost scales with the collection, or that allocates new elements.

## Prefer unary row views in `List`

`List` needs the identity of every row up front: it has to materialize the full id set to diff against the previous update. When each row is a single view per element, SwiftUI can template the row id from the `ForEach` element's id alone, without running each row's `body`. That fast path is what makes a long `List` cheap.

A row's final id combines the explicit id from `ForEach` with a bit of structural identity - roughly, a marker for which top-level view inside the row was produced. If the row body produces a single top-level view, structural identity is constant and each row's id is fully determined by the element's id. If the row body branches between different top-level shapes (a bare `switch`, a top-level `if`/`else`), the structural part varies per row. SwiftUI can't template from the first row because it can't assume subsequent rows took the same branch; it falls back to evaluating every row's body just to compute ids, and update cost scales with the number of rows.

```swift
// AVOID: The row view is "multi" - the top-level `switch` makes each row's
// structural identity depend on which case ran. To compute ids, SwiftUI
// has to evaluate every row's body, even for long lists.
struct ItemRow: View {
    var item: Item

    var body: some View {
        switch item.kind {
        case .plain:       Text(item.title)
        case .highlighted: Text(item.title).bold()
        case .disabled:    Text(item.title).foregroundStyle(.secondary)
        }
    }
}

struct ItemList: View {
    let items: [Item]

    var body: some View {
        List {
            ForEach(items) { item in
                ItemRow(item: item)
            }
        }
    }
}
```

```swift
// PREFER: Wrap the branching content in a container so the row is "unary"
// - one top-level view regardless of which case ran. SwiftUI can template
// ids from the ForEach without walking every row.
struct ItemRow: View {
    var item: Item

    var body: some View {
        VStack {
            switch item.kind {
            case .plain:       Text(item.title)
            case .highlighted: Text(item.title).bold()
            case .disabled:    Text(item.title).foregroundStyle(.secondary)
            }
        }
    }
}
```

Any single-root container works - `VStack`, `HStack`, `ZStack`, or a custom wrapper view. The point is to turn N possible top-level views into one.

Don't "fix" this by flattening the switch into a single shape with conditional modifiers (e.g. `Text(item.title).bold(item.kind == .highlighted)`). That happens to make this row unary only because all three cases produced the same top-level shape; it teaches the wrong lesson and breaks the moment cases produce structurally different views (Text vs Image vs Divider). Wrap the switch in a container instead.

### Unary vs multi views

A `View` is **unary** when its `body` produces a single top-level view (wrapped in `VStack`, `HStack`, `ZStack`, or another single-root container). It is **multi** when its body produces more than one top-level view, or branches between different top-level shapes. `Group` and `ForEach` are passthroughs, not containers - they do not make their contents unary. `Group { A(); B(); C() }` contributes the same three top-level views as writing `A(); B(); C()` directly.

For `List` rows, prefer unary. The fix is usually as simple as wrapping `body` in `VStack`.

### A top-level `if` without `else` is also multi

`ForEach`'s doc comment frames this fast path in terms of "constant number of views": each row's builder must produce the same number of top-level views for every element. A top-level `if` with no `else` produces either 0 or 1 views depending on the condition, so the count is not constant and the same fast path is defeated - SwiftUI has to evaluate every row's body to find out which elements contribute a row at all.

```swift
// AVOID: bare top-level `if` in a lazy container. The row is 0 or 1 view
// depending on `namedFont.name.count`, so the row builder does not produce
// a constant number of views and the List fast path is defeated.
ForEach(namedFonts) { namedFont in
    if namedFont.name.count != 2 {
        Text(namedFont.name)
    }
}
```

```swift
// PREFER: wrap in a single-root container so the row is always exactly one
// top-level view; the `if` becomes interior content.
ForEach(namedFonts) { namedFont in
    VStack {
        if namedFont.name.count != 2 {
            Text(namedFont.name)
        }
    }
}
```

If the intent is actually "skip this element", filter the collection before passing it to `ForEach` rather than producing a zero-view row. The wrapping fix is right when the row genuinely has optional content inside it; upstream filtering is right when some elements shouldn't be rows at all.

### Avoid `AnyView` as a `ForEach` row

`AnyView` erases the wrapped view's type, which erases its structural identity as well: SwiftUI can no longer tell from the type alone which shape a row produced. This defeats the same templating fast path as a top-level `switch` - the framework has to evaluate each row's body to find out what's inside.

```swift
// AVOID: Building rows as `AnyView`. Each row's structural identity is
// opaque to SwiftUI, so the List can't template ids and falls back to
// evaluating every row's body.
ForEach(items) { item in
    rowView(for: item) // returns AnyView
}

func rowView(for item: Item) -> AnyView {
    switch item.kind {
    case .plain:       return AnyView(Text(item.title))
    case .highlighted: return AnyView(Text(item.title).bold())
    case .disabled:    return AnyView(Text(item.title).foregroundStyle(.secondary))
    }
}
```

```swift
// PREFER: A concrete row view whose body uses `switch` or `if`/`else`
// inside a single-root container. The row's static shape is visible to
// SwiftUI, so it can template ids across the list.
struct ItemRow: View {
    var item: Item

    var body: some View {
        VStack {
            switch item.kind {
            case .plain:       Text(item.title)
            case .highlighted: Text(item.title).bold()
            case .disabled:    Text(item.title).foregroundStyle(.secondary)
            }
        }
    }
}

ForEach(items) { item in
    ItemRow(item: item)
}
```

The cost of `AnyView` is especially pronounced when it is the row of a `ForEach` feeding a `List`, because the loss of structural information scales with the number of rows. Prefer a concrete row view with `switch`/`if`/`else` inside a container over any design that reaches for `AnyView` to unify row types.

Don't "fix" this by replacing `AnyView` with a `@ViewBuilder` helper returning `some View`. The helper body is still a bare `switch` producing a `_ConditionalContent` tree — the row remains multi-shape and the same fast path is still defeated. Removing type erasure is only half the fix; the other half is wrapping the branching content inside a concrete row view with a single-root container.

### Diagnosing with `-LogForEachSlowPath`

To find non-constant row builders in an existing app, launch with:

```
-LogForEachSlowPath YES
```

SwiftUI logs each `ForEach` inside a lazy container (`List`, `LazyVStack`, and similar) whose row body produces a non-constant number of views. Use it to triage - the log points at the offending call sites so you can choose to refactor them.
