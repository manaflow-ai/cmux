# View Structure

A view is SwiftUI's unit of invalidation. When something changes, SwiftUI re-runs the body of the smallest enclosing view that depends on what changed. Factoring affects performance (not just readability), and `init` runs much more often than people expect. For what data each view should take as input and how that affects invalidation, see `dataflow.md`.

When building a new view with distinct sections — a header, a list, a footer, sidebar + main, content + counter, or any multi-region layout — declare each section as its own `struct` conforming to `View`. Do **not** factor sections as `private var` computed properties or `@ViewBuilder` helper methods on the parent. The sections below explain why and show the AVOID/PREFER patterns.

## Always use separate `View` types for sections, not computed properties

Long `var body` implementations are hard to read, but the more important problem is that everything inside the same body is part of the same invalidation boundary. When any input to a view changes, SwiftUI re-evaluates the entire body — every conditional, every modifier chain, every string interpolation — even if only one small leaf actually depends on what changed.

Factor large bodies into individual `View` types, not into computed properties or `@ViewBuilder` helper functions. A computed property is inlined into the enclosing view's body; it does not introduce its own invalidation boundary, so it does not reduce update cost. A separate `View` type with explicit, narrow inputs invalidates only when those inputs change.

```swift
// AVOID: Computed properties look like factoring but share the parent's
// invalidation boundary. Toggling `isExpanded` invalidates `ProfileView`,
// which re-evaluates `header`, `details`, AND `footer` together — even
// though only `details` actually reads `isExpanded`.
struct ProfileView: View {
    @State private var isExpanded = false
    let user: User
    let stats: Stats

    var body: some View {
        VStack {
            header
            details
            footer
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "person.circle")
            Text(user.name).font(.title)
        }
    }

    private var details: some View {
        Group {
            if isExpanded {
                Text(user.bio)
                Text(user.location)
            }
        }
    }

    private var footer: some View {
        HStack {
            Label("\(stats.followers)", systemImage: "person.2")
            Label("\(stats.posts)", systemImage: "doc.text")
        }
        .font(.caption)
    }
}
```

```swift
// PREFER: Each subview is its own invalidation boundary with its own
// inputs. Toggling `isExpanded` invalidates `ProfileView` and
// `ProfileDetails`; `ProfileHeader` and `ProfileFooter` are skipped
// because none of their inputs changed.
struct ProfileView: View {
    @State private var isExpanded = false
    let user: User
    let stats: Stats

    var body: some View {
        VStack {
            ProfileHeader(name: user.name)
            ProfileDetails(
                bio: user.bio,
                location: user.location,
                isExpanded: isExpanded
            )
            ProfileFooter(followers: stats.followers, posts: stats.posts)
            Button(isExpanded ? "Less" : "More") { isExpanded.toggle() }
        }
    }
}

struct ProfileHeader: View {
    let name: String

    var body: some View {
        HStack {
            Image(systemName: "person.circle")
            Text(name).font(.title)
        }
    }
}

struct ProfileDetails: View {
    let bio: String
    let location: String
    let isExpanded: Bool

    var body: some View {
        if isExpanded {
            Text(bio)
            Text(location)
        }
    }
}

struct ProfileFooter: View {
    let followers: Int
    let posts: Int

    var body: some View {
        HStack {
            Label("\(followers)", systemImage: "person.2")
            Label("\(posts)", systemImage: "doc.text")
        }
        .font(.caption)
    }
}
```

Pass each subview only the data it actually uses — the same rule as "Pass views only the data they read" in `dataflow.md`. The example above already follows it: each subview takes exactly the fields it reads, not the parent's full `User`/`Stats` structs.

Computed properties and small `@ViewBuilder` helpers still have a place for tiny fragments reused two or three times within the same body that have no independent invalidation story. The rule targets factoring done for *organization* or to manage *body length*, where a real `View` type does the right thing.

### Multi-section detail views

The most common write-from-requirements case where this rule gets dropped: a prompt asks for a `SomethingDetailView` with multiple distinct sections — header + body + metadata + related items, header + ingredients + steps + footer, hero + description + specs + reviews, etc. The training-data shape for this prompt is "single `View` with `private var header: some View`, `private var body: some View`, etc." That shape is wrong. Always factor each named section as a separate `View` type with narrow inputs.

```swift
// PREFER: Detail view with multiple sections, each section a separate
// `View` type that takes only the fields it renders. The parent stays
// thin — it just composes the sections.
struct ProductDetailView: View {
    let product: Product

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ProductHeader(name: product.name, price: product.price)
                ProductGallery(images: product.imageURLs)
                ProductDescription(text: product.descriptionText)
                ProductReviews(
                    averageStars: product.averageStars,
                    reviewCount: product.reviewCount
                )
            }
            .padding()
        }
    }
}

struct ProductHeader: View {
    let name: String
    let price: Decimal

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.largeTitle).fontWeight(.bold)
            Text(price, format: .currency(code: "USD"))
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}

struct ProductGallery: View {
    let images: [URL]

    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(images, id: \.self) { url in
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.secondary.opacity(0.2)
                    }
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

struct ProductDescription: View {
    let text: String

    var body: some View {
        Text(text).font(.body)
    }
}

struct ProductReviews: View {
    let averageStars: Double
    let reviewCount: Int

    var body: some View {
        HStack {
            Label("\(averageStars, specifier: "%.1f")", systemImage: "star.fill")
            Text("(\(reviewCount) reviews)")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}
```

This shape generalizes to every other detail view: `MovieDetailView`, `RecipeDetailView`, `ArticleDetailView`, `ProfileDetailView`, `EpisodeDetailView`. Same factoring every time — one `View` type per section, narrow inputs each, thin parent that composes them. Don't reach for `private var header: some View` on the parent.

## Keep view `init` cheap

A view's `init` runs every time the parent re-evaluates its body, which can be many times per second for views inside `List`, `LazyVStack`, scroll containers, or animated parents. Treat `init` as a constant-time copy of inputs into stored properties. Don't load data, decode JSON, touch the file system, format dates, or allocate large structures there.

```swift
// AVOID: Expensive work in `init`. Every time the parent's body runs,
// the JSON is decoded again, the date formatter is allocated again,
// and the formatted string is rebuilt — even though the inputs haven't
// changed.
struct WeatherCard: View {
    let summary: WeatherSummary
    let formattedDate: String

    init(rawJSON: Data, date: Date) {
        self.summary = try! JSONDecoder().decode(WeatherSummary.self, from: rawJSON)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        self.formattedDate = formatter.string(from: date)
    }

    var body: some View {
        VStack {
            Text(summary.headline)
            Text(formattedDate)
        }
    }
}
```

```swift
// PREFER: Inputs are already-prepared values. Decoding lives in the
// model layer (or in a `.task`); formatting uses SwiftUI's built-in
// `Text(_:format:)` which is cached and locale-aware.
struct WeatherCard: View {
    let summary: WeatherSummary
    let date: Date

    var body: some View {
        VStack {
            Text(summary.headline)
            Text(date, format: .dateTime.day().month().year())
        }
    }
}
```

If a derived value really does need to be computed once and cached for the view's lifetime, store it on an `@State`-owned `@Observable` model or compute it asynchronously in `.task`. `init` is not a one-time setup hook; it runs as often as the parent's body does.

## Single Child `Group`

`Group { SomeView() }`, which is a `Group` with only one child, isn't free. Even though it has no visual effect, it wraps the view in an additional type, `Group<SomeView>`. Every modifier you chain after it (`.onChange`, `.background`, `.frame`, etc.) has to be type-checked against that wrapped type instead of the underlying view's type. In long modifier chains this extra type wrapper can add totally unnecessary type checking overhead.

The "single child" rule is specifically about *one concrete view*. A `Group` whose content is a `ForEach`, a `TupleView` of sibling views, or an `if`/`else` (which produces `_ConditionalContent`) is doing real work and is fine.

```swift
// AVOID: A single concrete child inside Group. The Group wraps `Text` in
// an extra type that every chained modifier must type-check against, for
// no behavioral benefit.
Group {
    Text(status)
}
.padding(.horizontal, 8)
.background(.thinMaterial, in: Capsule())
```

```swift
// PREFER: Drop the Group and chain the modifiers directly on the child.
Text(status)
    .padding(.horizontal, 8)
    .background(.thinMaterial, in: Capsule())
```

```swift
// PREFER: Multiple siblings is exactly what Group is for — modifiers
// apply to each child as a unit without needing an HStack/VStack
// container that would change layout.
Group {
    Button("Save", action: onSave)
    Button("Cancel", action: onCancel)
    Button("Delete", role: .destructive, action: onDelete)
}
.buttonStyle(.borderedProminent)
.controlSize(.large)
```

```swift
// PREFER: Wrapping an `if`/`else` in Group so a shared modifier applies
// uniformly to both branches. This is NOT the single-child anti-pattern —
// the Group's content is `_ConditionalContent<...>`, not a single concrete
// view, and removing the Group would either drop the modifier from one
// branch or force you to repeat it on both.
Group {
    if let label {
        Text(label)
            .padding(4)
            .background(.thinMaterial, in: Capsule())
    } else {
        Color.clear
    }
}
.accessibilityHidden(label == nil)
```