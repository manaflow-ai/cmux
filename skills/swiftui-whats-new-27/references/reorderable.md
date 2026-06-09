# Reorderable Containers
**SDK Version:** 27.0 and later

SwiftUI now supports drag-to-reorder in *any* container (`List`, `LazyVStack`, `LazyVGrid`, stacks, or a custom layout), not just `List`. Previously, drag-to-reorder was effectively `List`-only (via `onMove(perform:)`) or hand-rolled with a drag gesture. Two modifiers work together: `.reorderable()` goes on the `ForEach` (it is declared on `DynamicViewContent`), and `.reorderContainer(for:…)` goes on the enclosing container. When a drag ends, SwiftUI calls your `move` closure with a `ReorderDifference` describing the change, which you apply to your own data.

**Availability:** iOS 27, macOS 27, watchOS 27, visionOS 27. **tvOS: unavailable.**

If the user's deployment target is below iOS 27 / macOS 27 / watchOS 27 / visionOS 27, do not use these APIs unconditionally.

## Basic usage

```swift
struct StickerGrid: View {
    @State private var stickers: [Sticker] = []

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns) {
                ForEach(stickers) { sticker in
                    StickerView(sticker)
                }
                .reorderable()
            }
            .reorderContainer(for: Sticker.self) { difference in
                // Update `stickers` to reflect the move (see "Applying the difference").
            }
        }
    }
}
```

`Sticker` must be `Identifiable` for the `for:` overload (it keys on `\.id`). If your type is not `Identifiable`, or you want a different identifier, use the `itemID:` keypath overload: `reorderContainer(for: Sticker.self, itemID: \.code)` paired with the same `.reorderable()`.

## Applying the difference

Your `move` closure receives a `ReorderDifference<ItemID, CollectionID>`:

```swift
public struct ReorderDifference<ItemID, CollectionID> {
    public var sources: [ItemID]            // the items being moved
    public var destination: Destination

    public struct Destination {
        @frozen public enum Position {
            case before(ItemID)             // insert the sources before this item
            case end                        // append the sources to the end
        }
        public var position: Position
        public var collectionID: CollectionID
    }
}
```

`sources` is the items being moved; `destination.position` is where they go (`.before(id)` places them ahead of that item, `.end` appends). Apply this to your data however fits your model. As one example, using a `Set` for O(1) membership and a single in-place pass, factored into a reusable extension on `ReorderDifference`:

```swift
extension ReorderDifference where CollectionID == ReorderableSingleCollectionIdentifier {
    func apply<C>(to collection: inout C)
        where C: RangeReplaceableCollection,
              C.Element: Identifiable,
              C.Element.ID == ItemID
    {
        let moving = Set(sources)
        guard !moving.isEmpty else { return }

        // One in-place pass: drop the moved items and capture them in order.
        var moved: [C.Element] = []
        moved.reserveCapacity(moving.count)
        collection.removeAll { element in
            guard moving.contains(element.id) else { return false }
            moved.append(element)
            return true
        }

        switch destination.position {
        case .before(let id):
            let index = collection.firstIndex { $0.id == id } ?? collection.endIndex
            collection.insert(contentsOf: moved, at: index)
        case .end:
            collection.append(contentsOf: moved)
        }
    }
}
```

(That example's `CollectionID == ReorderableSingleCollectionIdentifier` constraint scopes it to single-collection containers; sectioned containers route by `destination.collectionID` instead. See below.)

## Sections and multiple collections

When a container has more than one collection (for example, `List` sections), tag each `ForEach` with `.reorderable(collectionID:)` and declare the collection identifier type on the container with `reorderContainer(for:in:)`:

```swift
struct Category: Identifiable {
    let id = UUID()
    var name: String
    var items: [Item]
}

// In your view's body:
List {
    ForEach(categories) { category in
        Section(category.name) {
            ForEach(category.items) { item in
                ItemView(item)
            }
            .reorderable(collectionID: category.id)
        }
    }
}
.reorderContainer(for: Item.self, in: Category.ID.self) { difference in
    // Apply the move. difference.destination.collectionID identifies the
    // destination section; remove the items from their old section and insert
    // them at difference.destination.position.
}
```

The type you pass to `in:` is your section model's `ID` (here `Category.ID`), not SwiftUI's `Section`. For a single-collection container, the `CollectionID` is `ReorderableSingleCollectionIdentifier` (an opaque empty identifier SwiftUI supplies for you).

## Drag-and-drop integration

`.reorderContainer(for:)` already acts as a drag container and a drop destination, so dragging to reorder works on its own. To customize it, declare your own `dragContainer(for:)` (to control selection, the dragged item representation, or to let items drag out to other views and apps) or `dropDestination(for:)` (to accept dropped items at the reorder position) on the same container. A standalone `.draggable` does not customize the reorder container; provide a `dragContainer` instead.

> **Availability:** these drag-and-drop modifiers are iOS 27 / visionOS 27, and macOS 26 to 27. `dragContainer` / `draggable(containerItemID:)` / `dropDestination` are macOS 26, but `DropSession.reorderDestination(for:)` requires macOS 27 (see the table below). tvOS and **watchOS are unavailable**, so a reorderable list works on watchOS (reordering is local to the container), but this drag-and-drop integration, which relies on system-wide drag and drop, does not.

**Customize the drag.** Declare your own `dragContainer(for:)` on the container to build the drag payload from an item identifier. `.reorderable()` already marks each child as draggable through the container, so the children themselves stay bare:

```swift
LazyVGrid(columns: columns) {
    ForEach(stickers) { sticker in
        StickerView(sticker)
    }
    .reorderable()
}
.reorderContainer(for: Sticker.self) { difference in /* apply the move to stickers */ }
.dragContainer(for: Sticker.self) { draggedID in
    stickers.first { $0.id == draggedID }.map { [$0] } ?? []
}
```

Return an empty collection from the `dragContainer` closure to disable the drag for a given item.

**Combining items: drop one onto another.** Put `.dropDestination(for:isEnabled:)` on each child. SwiftUI invokes the closure only when `isEnabled` is true, so a per-item predicate (`canCombine`, a state check, etc.) goes in `isEnabled:`, not inside the closure. The closure's signature is `(items: [T], session: DropSession) -> Void`. SwiftUI handles drop visualization itself: while a drag hovers an `isEnabled` child, the system signals that item as the drop target, and when the drag moves between children the system shows a reorder gap. You do not need to add hover state to your view. Do not use the `dropDestination(for:) { } isTargeted: { }` overload here; that overload reports hover state for custom visual feedback, it does not gate combining, and it is the wrong choice for drop-to-combine.

```swift
LazyVGrid(columns: columns) {
    ForEach(stickers) { sticker in
        StickerView(sticker)
            .dropDestination(for: Sticker.self, isEnabled: sticker.allowsCombining) { items, _ in
                // Void-returning: no `return true` / `return false` in this closure.
                guard let i = stickers.firstIndex(where: { $0.id == sticker.id }) else { return }
                let droppedIDs = Set(items.map(\.id))
                stickers[i].name = ([stickers[i].name] + items.map(\.name)).joined(separator: "+")
                stickers.removeAll { droppedIDs.contains($0.id) }
            }
    }
    .reorderable()
}
.reorderContainer(for: Sticker.self) { difference in difference.apply(to: &stickers) }
.dragContainer(for: Sticker.self) { draggedID in
    stickers.first { $0.id == draggedID }.map { [$0] } ?? []
}
```

**Accepting drops at the reorder position.** Put `.dropDestination(for:)` on the container and ask the session where the drop landed via `reorderDestination(for:)`, which returns a `ReorderDifference.Destination?` (`nil` means the person dropped without hovering a specific item; append to the end in that case). This overload is for placement, not combining; for combine, use the per-child form above.

```swift
.dropDestination(for: Sticker.self) { items, session in
    guard let destination = session.reorderDestination(for: Sticker.self) else {
        stickers.append(contentsOf: items)
        return
    }
    switch destination.position {
    case .before(let id):
        let index = stickers.firstIndex { $0.id == id } ?? stickers.endIndex
        stickers.insert(contentsOf: items, at: index)
    case .end:
        stickers.append(contentsOf: items)
    }
}
```

## Availability summary

| API | iOS | macOS | watchOS | tvOS | visionOS |
|---|---|---|---|---|---|
| `reorderable()` / `reorderContainer(for:…)` | 27 | 27 | 27 | n/a | 27 |
| `dragContainer` / `draggable(containerItemID:)` | 27 | 26 | n/a | n/a | 27 |
| `DropSession` / `dropDestination(for:…session…)` | 26 | 26 | n/a | n/a | 26 |
| `DropSession.reorderDestination(for:)` | 27 | 27 | n/a | n/a | 27 |
