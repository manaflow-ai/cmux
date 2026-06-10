# Toolbar
**SDK Version:** 27.0 and later

If the user's deployment target is below iOS 27 / macOS 27 / watchOS 27 / visionOS 27, the new APIs in this reference (`visibilityPriority(_:)`, `ToolbarOverflowMenu` and its `toolbarOverflowMenu` modifier, `.topBarPinnedTrailing`, `toolbarMinimizeBehavior(_:for:)`, `toolbarMinimizationSafeAreaAdjustment(_:for:)`, `contentMarginsRemoved(_:)`, `ToolbarPlacement.statusBar`, and `EmptyView` as toolbar content) require availability gating. The `ForEach` toolbar conformance back-deploys to iOS 16 / macOS 13 / watchOS 9 / tvOS 16 / visionOS 1 when built with the 2027 SDK and does not need gating. See "Deployment target below SDK 27" below for the gating shape to use.

When a toolbar has more items than fit the available width (a narrow window, a resized app, or iPhone), the system moves the overflow into a trailing overflow menu. The 2027 SDKs add modifiers to control what stays in the bar, what overflows, and what is pinned, to minimize a bar as the person scrolls, and to adjust toolbar content margins and status-bar visibility. `ForEach` and `EmptyView` also work inside a `toolbar` builder now.

## Visibility priority

`visibilityPriority(_:)` sets how readily a piece of `ToolbarContent` (a `ToolbarItem` or `ToolbarItemGroup`) overflows when space is tight: higher-priority content stays in the bar, lower-priority content moves to the overflow menu first. The priorities are `.automatic` (the default), `.low`, and `.high`, or you can derive one relative to another with `ToolbarItemVisibilityPriority(higherThan:)` or `(lowerThan:)`.

```swift
.toolbar {
    ToolbarItemGroup {
        UndoButton()
        RedoButton()
    }
    .visibilityPriority(.high)
}
```

**Availability:** iOS 27, macOS 26.1, watchOS 27, tvOS 27, visionOS 27. `.low` and `.high` are iOS and macOS only; the relative initializers are iOS 27 / macOS 27. On watchOS, tvOS, and visionOS only `.automatic` exists.

## Overflow menu

`ToolbarOverflowMenu` holds content that always lives in the overflow menu instead of the bar. Its body is a view builder, so the buttons go directly inside it. The `.toolbarOverflowMenu { }` modifier on `View` does the same outside a `toolbar` builder.

```swift
.toolbar {
    ToolbarOverflowMenu {
        ChoosePhotoButton()
        ExportAsImageButton()
        ClearAllStickersButton()
    }
}
```

**Availability:** iOS 27, visionOS 27.

## Pinned trailing item

A `ToolbarItem` placed with `.topBarPinnedTrailing` stays in the trailing position and never moves to the overflow menu, no matter how constrained the bar is.

```swift
.toolbar {
    ToolbarItem(placement: .topBarPinnedTrailing) {
        ShareButton()
    }
}
```

**Availability:** iOS 27, visionOS 27.

## Minimize on scroll

`toolbarMinimizeBehavior(_:for:)` minimizes a bar as the person scrolls. It takes one of `ToolbarMinimizeBehavior.automatic` (the system decides), `.onScrollDown`, `.onScrollUp`, or `.never`. The companion `toolbarMinimizationSafeAreaAdjustment(_:for:)` controls whether content's safe area shrinks to follow the bar as it minimizes, with `.automatic`, `.enabled`, or `.disabled`.

```swift
ScrollView {
    StickerListView()
}
.toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)  // or .automatic, .onScrollUp, .never
```

**Availability:** iOS 27, macOS 27, watchOS 27, tvOS 27, visionOS 27. `.onScrollDown` / `.onScrollUp` / `.never` and `.enabled` / `.disabled` are iOS only; other platforms use `.automatic`.

## Toolbar content margins

`contentMarginsRemoved(_:)` removes the default margins around a piece of toolbar content, so it sits flush with the edge of the bar.

```swift
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        AvatarView()
    }
    .contentMarginsRemoved()
}
```

**Availability:** iOS 27, macOS 27, watchOS 27, tvOS 27, visionOS 27.

## Status bar visibility

The status bar is now a `ToolbarPlacement`, so you control its visibility with `toolbarVisibility(_:for:)`. On iOS this is the replacement for `statusBarHidden(_:)`.

```swift
.toolbarVisibility(.hidden, for: .statusBar)
```

**Availability:** iOS 27.

## Dynamic content

`ForEach` now conforms to `ToolbarContent`, so a `toolbar` builder can generate items from a collection just as a view body does. `EmptyView` conforms now as well, for an explicit empty branch. (Conditionals such as `if` and `#if`, and multiple items in one builder, already worked before 27.)

```swift
.toolbar {
    ForEach(quickActions) { action in
        ToolbarItem {
            Button(action.title) { action.perform() }
        }
    }
}
```

**Availability:** the `ForEach` conformance back-deploys (iOS 16, macOS 13, watchOS 9, tvOS 16, visionOS 1) when built with the 2027 SDK; the `EmptyView` conformance requires iOS 27, macOS 27, watchOS 27, tvOS 27, visionOS 27.

## Deployment target below SDK 27

When the user's deployment target is below SDK 27 and the answer needs any of the new APIs above, gate the whole `.toolbar { … }` body in a single `if #available` block and provide a fallback for older OS versions. Conditionals already worked in toolbar builders before SDK 27, so this is the cleanest place to put the gate:

```swift
.toolbar {
    if #available(iOS 27, *) {
        // New SDK 27 APIs go here, for example:
        ToolbarItemGroup { /* … */ }
            .visibilityPriority(.high)
        ToolbarItem(placement: .topBarPinnedTrailing) { /* … */ }
        ToolbarOverflowMenu { /* … */ }
    } else {
        // Older fallback: plain ToolbarItem entries (or whatever older toolbar shape works for the app).
        ToolbarItem { /* … */ }
    }
}
```

Use this shape (or `@available(iOS 27, *)` on an enclosing declaration) whenever the prompt names a deployment target below SDK 27. Don't emit unconditional calls to the APIs above; the typecheck will fail with `'<API>' is only available in iOS 27.0 or newer`.

## Availability summary

| API | iOS | macOS | watchOS | tvOS | visionOS |
|---|---|---|---|---|---|
| `visibilityPriority(_:)`, `.automatic` | 27 | 26.1 | 27 | 27 | 27 |
| `.low` / `.high` | 27 | 26.1 | n/a | n/a | n/a |
| `init(lowerThan:)` / `init(higherThan:)` | 27 | 27 | n/a | n/a | n/a |
| `ToolbarOverflowMenu` / `toolbarOverflowMenu` | 27 | n/a | n/a | n/a | 27 |
| `.topBarPinnedTrailing` | 27 | n/a | n/a | n/a | 27 |
| `toolbarMinimizeBehavior(_:for:)`, `.automatic` | 27 | 27 | 27 | 27 | 27 |
| `.onScrollDown` / `.onScrollUp` / `.never` | 27 | n/a | n/a | n/a | n/a |
| `toolbarMinimizationSafeAreaAdjustment(_:for:)`, `.automatic` | 27 | 27 | 27 | 27 | 27 |
| `.enabled` / `.disabled` (safe-area adjustment) | 27 | n/a | n/a | n/a | n/a |
| `contentMarginsRemoved(_:)` | 27 | 27 | 27 | 27 | 27 |
| `ToolbarPlacement.statusBar` | 27 | n/a | n/a | n/a | n/a |
| `ForEach` as toolbar content (back-deploys) | 16 | 13 | 9 | 16 | 1 |
| `EmptyView` as toolbar content | 27 | 27 | 27 | 27 | 27 |
