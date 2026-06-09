# Swipe Actions
**SDK Version:** 27.0 and later

The `swipeActions(edge:allowsFullSwipe:content:)` row modifier previously took effect only inside a `List`. The 2027 SDKs let it work in any scrollable container (a `ScrollView` containing a `LazyVStack`, `LazyVGrid`, or a stack) once that container is marked with the new `swipeActionsContainer()` modifier, which coordinates the swipe across the items in the container. A new overload of the row modifier adds an `onPresentationChanged` callback that reports when a row's actions are revealed or hidden.

If the user's deployment target is below iOS 27 / macOS 27 / watchOS 27 / visionOS 27, the new `swipeActionsContainer()` modifier and the `swipeActions(…onPresentationChanged:)` overload require availability gating. The original `swipeActions(edge:allowsFullSwipe:content:)` row modifier on a `List` row has been available since iOS 15 / macOS 12 / watchOS 8 / visionOS 1 and does not need gating.

## Swipe actions in a scrollable container

Put `swipeActionsContainer()` on the scrollable container and keep the existing `swipeActions(edge:allowsFullSwipe:content:)` on each row inside it. The row modifier is unchanged: `edge` defaults to `.trailing` (pass `.leading` for the leading edge), `allowsFullSwipe` defaults to `true`, and the content builder holds the buttons.

```swift
struct StickerListView: View {
    @State private var stickers: [Sticker] = []

    var body: some View {
        ScrollView {
            LazyVStack {
                ForEach(stickers) { sticker in
                    StickerRow(sticker)
                        .swipeActions {
                            Button(role: .destructive) {
                                stickers.removeAll { $0.id == sticker.id }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .swipeActionsContainer()
    }
}
```

Without `swipeActionsContainer()` on the container, `swipeActions` on a row outside a `List` has no effect. The modifier also applies to a `LazyVGrid` or a plain stack inside the `ScrollView`.

**Availability:** `swipeActionsContainer()` is iOS 27, macOS 27, watchOS 27, visionOS 27; tvOS unavailable. The `swipeActions(edge:allowsFullSwipe:content:)` row modifier is iOS 15, macOS 12, watchOS 8, visionOS 1; tvOS unavailable.

## Reacting when actions are shown or hidden

The `swipeActions(edge:allowsFullSwipe:content:onPresentationChanged:)` overload adds an `onPresentationChanged` closure that receives `true` when the row's actions become visible and `false` when they hide.

```swift
StickerRow(sticker)
    .swipeActions {
        Button(role: .destructive) {
            stickers.removeAll { $0.id == sticker.id }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    } onPresentationChanged: { isPresented in
        revealedSticker = isPresented ? sticker.id : nil
    }
```

**Availability:** iOS 27, macOS 27, watchOS 27, visionOS 27; tvOS unavailable.

## Availability summary

| API | iOS | macOS | watchOS | tvOS | visionOS |
|---|---|---|---|---|---|
| `swipeActions(edge:allowsFullSwipe:content:)` (row modifier) | 15 | 12 | 8 | n/a | 1 |
| `swipeActionsContainer()` | 27 | 27 | 27 | n/a | 27 |
| `swipeActions(…onPresentationChanged:)` | 27 | 27 | 27 | n/a | 27 |
