# Conditional View Modifiers

Never write a conditional view modifier (sometimes called an `.if` modifier) that uses `@ViewBuilder` to switch between `transform(self)` and `self` based on a boolean. If you encounter an existing conditional view modifier in the codebase, do not remove or refactor it (doing so can change behavior and is out of scope), but when reviewing, point out that it may cause unexpected behavior and explain the alternatives below.

## Why conditional view modifiers are problematic

1. **View identity loss**: The `if`/`else` inside the modifier creates two branches with different view types. When the condition toggles, SwiftUI sees a completely different view rather than a modified version of the same view. This breaks structural identity.
2. **State reset**: Any `@State` in the view or its descendants resets when the condition changes, because SwiftUI treats the two branches as distinct views.
3. **Broken animations**: Instead of smoothly animating a property change, SwiftUI removes one view and inserts another, producing an abrupt transition.

```swift
// AVOID: A conditional view modifier extension.
// This destroys structural identity every time `condition` toggles.
extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// Usage of the anti-pattern:
Text("Hello")
    .if(isHighlighted) { $0.foregroundStyle(.red) }
```

```swift
// PREFER: Use a ternary expression in the modifier argument.
// The view identity is preserved and SwiftUI animates the change smoothly.
Text("Hello")
    .foregroundStyle(isHighlighted ? .red : .primary)
```
