# ContentBuilder Unification
**SDK Version:** 27.0 and later

Many of SwiftUI's result builders (most notably `@ViewBuilder`) have been unified under `@ContentBuilder`. This changes the type-checking model: result builders no longer constrain their block contents to conform to `View`. As a result, you may encounter source incompatibilities in existing code. Here are the issues and how to fix them:

## Ambiguous ShapeStyle Modifiers in `overlay` or `background`
**Issue:**
Code that passes a `ShapeStyle` expression with modifiers like `.opacity()` or `.blendMode()` directly to the deprecated non-builder `overlay` or `background` may produce:

```
error: ambiguous use of 'opacity'
error: ambiguous use of 'blendMode'
```

For example, this code will fail to compile:
```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("Hello")
            .overlay(Color.blue.opacity(0.70).blendMode(.overlay))
    }
}
```

**Fix:**
Use the trailing-closure variant of `overlay` or `background` instead of passing the expression as a direct argument.

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        Rectangle()
            .overlay { Color.blue.opacity(0.3).blendMode(.overlay) }
    }
}
```

**Reason:**
The `overlay` and `background` modifiers each have two overloads: one accepting a `View` (marked as disfavored) and one accepting a `ShapeStyle`. Separately, modifiers like `.opacity()` and `.blendMode()` on `ShapeStyle` are also overloaded to return either a `ShapeStyle` or a `View`. Previously, `@ViewBuilder`'s `View` constraint forced the compiler to pick the `View`-returning variant of `.opacity()`, which then resolved `overlay` unambiguously to the `ShapeStyle` overload.

With `@ContentBuilder` removing the `View` constraint, the `ShapeStyle`-returning variant of `.opacity()` must now be disfavored to preserve the previous default behavior. However, this creates a new problem when combined with `overlay`: each possible resolution path has exactly one disfavored overload (either the `View`-accepting `overlay` or the `ShapeStyle`-returning `.opacity()`), making the overall expression ambiguous. Using the trailing-closure variant explicitly selects the builder-based overload of `overlay`, breaking the tie.

## Ambiguous Type References When Another Module Shadows SwiftUI Types
**Issue:**
If your project imports a module that declares a type with the same name as a SwiftUI type (for example, its own `Color` type with a `.red` property), you may see:

```
error: ambiguous use of 'red'
```

This can occur with any duplicated static member (e.g., `.green`, `.blue`, `.clear`), not just `.red`, or a type with the same name as a SwiftUI type. For example, if a framework declared a type called `Text` with overloads that match those found in SwiftUI's `Text`, this would now be ambiguous. The common theme is that these were previously only disambiguated by the `View` constraint on `@ViewBuilder`'s `buildBlock`.

For example, this code will fail to compile if `MyPackage` also declares a `Color` type with a `.clear` member:
```swift
// In MyPackage:
public struct Color {
    public static let clear = Color()
}

// In your app:
import SwiftUI
import MyPackage

struct ContentView: View {
    var body: some View {
        Color.clear
    }
}
```

**Fix:**
Fully qualify the type to disambiguate which module's type you intend to use, or rename the type / members in `MyPackage` to make them distinct from those in SwiftUI.

```swift
import SwiftUI
import MyPackage

struct ContentView: View {
    var body: some View {
        SwiftUI.Color.clear
    }
}
```

**Reason:**
Previously, `@ViewBuilder`'s `View` constraint helped the compiler disambiguate between identically-named types across modules, because it could rule out the non-`View`-conforming candidate. With `@ContentBuilder` removing that constraint, the compiler sees both candidates as equally valid and reports an ambiguity.

## `TupleContent` vs `TupleView` Type Mismatch
**Issue:**
Code that explicitly references `TupleView` as a nested generic type parameter may produce:

```
error: cannot convert value of type 'VStack<TupleContent<Text, Text>>' to expected argument type 'VStack<TupleView<(Text, Text)>>'
```

This appears when `TupleView` is nested inside another container's generic parameter:
```
error: cannot convert value of type 'Label<TupleContent<Text, Text?>, Image?>' to expected argument type 'Label<TupleView<(Text, Optional<Text>)>, Optional<Image>>'
```

For example, this code will fail to compile:
```swift
import SwiftUI

struct CardView<Content: View>: View {
    var content: Content
    var body: some View { content }
    init(@ContentBuilder content: () -> Content) {
        self.content = content()
    }
}

extension CardView where Content == VStack<TupleView<(Text, Text)>> {
    init(title: String, subtitle: String) {
        self = CardView {
            VStack {
                Text(title)
                Text(subtitle)
            }
        }
    }
}
```

**Fix:**
Avoid hard-coding `TupleContent` or `TupleView` in generic type parameters. If you must spell the concrete type, use `TupleContent` instead of `TupleView` to match the new builder return type. If your deployment target is lower than any Apple OS 27.0, you can explicitly construct a `TupleView` inside the builder instead. Prefer using `some View` or other opaque types where possible.

```swift
import SwiftUI

struct CardView<Content: View>: View {
    var content: Content
    var body: some View { content }
    init(@ContentBuilder content: () -> Content) {
        self.content = content()
    }
}

extension CardView where Content == VStack<TupleContent<Text, Text>> {
    init(title: String, subtitle: String) {
        self = CardView {
            VStack {
                Text(title)
                Text(subtitle)
            }
        }
    }
}
```

or if your deployment target is lower than any Apple OS 27.0, you can do the equivalent with `TupleView`:

```swift
import SwiftUI

struct CardView<Content: View>: View {
    var content: Content
    var body: some View { content }
    init(@ContentBuilder content: () -> Content) {
        self.content = content()
    }
}

extension CardView where Content == VStack<TupleView<(Text, Text)>> {
    init(title: String, subtitle: String) {
        self = CardView {
            VStack {
                TupleView((
                    Text(title),
                    Text(subtitle)
                ))
            }
        }
    }
}
```

**Reason:**
The unified `@ContentBuilder` produces `TupleContent` rather than `TupleView` as the concrete return type for multi-expression builder blocks. When `TupleView` appears as a nested generic parameter (e.g., `VStack<TupleView<...>>`), the contextual type cannot propagate deep enough to guide the inner builder, causing a type mismatch. Updating the constraint to use `TupleContent`, or explicitly constructing `TupleView` inside the builder, resolves the issue.

## Empty Builder Body with MapKit
**Issue:**
When both SwiftUI and MapKit are dependencies of the same file an empty result builder body (or a `#if` block with no `#else` branch) inside of a nested builder will produce:

```
error: return type of property 'body' requires that 'EmptyMapContent' conform to 'View'
```

Note that this can happen even in files where `MapKit` is not explicitly imported if the project does not have member import visibility turned on. For this reason, do not rule this issue out just because the file doesn't import `MapKit`.

For example, this code will fail to compile:

```swift
import SwiftUI
import MapKit

struct ContentView: View {
    var body: some View {
        Group { }
    }
}
```

**Fix:**
Explicitly use `EmptyContent` (or `EmptyView`) rather than leaving the block empty.

```swift
import SwiftUI
import MapKit

struct ContentView: View {
    var body: some View {
        Group {
            EmptyContent()
        }
    }
}
```

**Issue:**
This also commonly occurs with conditional compilation blocks, as you can end up with an empty block in your else branch, for example the following code runs into the same issue when `MY_CONDITION` is `FALSE` as the block becomes empty:

```swift
import SwiftUI
import MapKit

struct ContentView: View {
    var body: some View {
        Group {
            #if MY_CONDITION
            MyView()
            #endif
        }
    }
}
```

**Fix:**
Add an explicit else branch with an `EmptyContent` (or `EmptyView`).

```swift
import SwiftUI
import MapKit

struct ContentView: View {
    var body: some View {
        Group {
            #if MY_CONDITION
            MyView()
            #else
            EmptyContent()
            #endif
        }
    }
}
```

**Reason:**
Without the `View` constraint on the builder, an empty builder body becomes ambiguous when MapKit is also imported, because MapKit defines its own result builder that can produce `EmptyMapContent`. Providing an explicit `EmptyContent()` (or `EmptyView()`) resolves the ambiguity by giving the compiler a concrete `View`-conforming expression.

## Type-Check Timeout in Swift Charts with Deeply Branching Content (Back-Deployment Only)
**Issue:**
When your project's minimum deployment target is lower than any Apple OS 27.0, deeply branching `if`/`else if` or `switch` statements inside a `Chart` closure may produce:

```
error: the compiler is unable to type-check this expression in reasonable time
```

This only occurs when back-deploying — projects that target OS 27.0 or later are not affected. It typically manifests when the branching logic has many cases (roughly 10+).

For example, this code will fail to compile:
```swift
import SwiftUI
import Charts

struct DataPoint {
    var index: Int
    var rate: Double
    var signal: Double
    var noise: Double
    var errors: Double
    var throughput: Double
    var txRate: Double
    var rxRate: Double
    var txFrames: Double
    var rxFrames: Double
    var channel: Double
    var bandwidth: Double
    var defaultValue: Double
}

struct MetricChartView: View {
    var selectedMetric: String
    var dataPoints: [DataPoint]

    var body: some View {
        Chart(dataPoints, id: \.index) { dataPoint in
            if selectedMetric == "Rate" {
                LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.rate))
                    .foregroundStyle(.blue)
            } else if selectedMetric == "Signal" {
                LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.signal))
                    .foregroundStyle(.green)
            } else if selectedMetric == "Noise" {
                LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.noise))
                    .foregroundStyle(.red)
            } else if selectedMetric == "Errors" {
                LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.errors))
                    .foregroundStyle(.orange)
            } else if selectedMetric == "Throughput" {
                LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.throughput))
                    .foregroundStyle(.purple)
            } else if selectedMetric == "TX Rate" {
                LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.txRate))
                    .foregroundStyle(.cyan)
            } else if selectedMetric == "RX Rate" {
                LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.rxRate))
                    .foregroundStyle(.mint)
            } else if selectedMetric == "TX Frames" {
                LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.txFrames))
                    .foregroundStyle(.indigo)
            } else if selectedMetric == "RX Frames" {
                LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.rxFrames))
                    .foregroundStyle(.brown)
            } else if selectedMetric == "Channel" {
                LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.channel))
                    .foregroundStyle(.teal)
            } else if selectedMetric == "Bandwidth" {
                LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.bandwidth))
                    .foregroundStyle(.pink)
            } else {
                LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.defaultValue))
                    .foregroundStyle(.gray)
            }
        }
    }
}
```

**Fix:**
Extract the branching logic into a separate function annotated with `@ChartContentBuilder`. This switches back to the existing model for typechecking back-deployed code.

```swift
import SwiftUI
import Charts

struct MetricChartView: View {
    var selectedMetric: String
    var dataPoints: [DataPoint]

    var body: some View {
        Chart(dataPoints, id: \.index) { dataPoint in
            marks(for: dataPoint)
        }
    }

    @ChartContentBuilder
    private func marks(for dataPoint: DataPoint) -> some ChartContent {
        if selectedMetric == "Rate" {
            LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.rate))
                .foregroundStyle(.blue)
        } else if selectedMetric == "Signal" {
            LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.signal))
                .foregroundStyle(.green)
        } else if selectedMetric == "Noise" {
            LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.noise))
                .foregroundStyle(.red)
        } else if selectedMetric == "Errors" {
            LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.errors))
                .foregroundStyle(.orange)
        } else if selectedMetric == "Throughput" {
            LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.throughput))
                .foregroundStyle(.purple)
        } else if selectedMetric == "TX Rate" {
            LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.txRate))
                .foregroundStyle(.cyan)
        } else if selectedMetric == "RX Rate" {
            LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.rxRate))
                .foregroundStyle(.mint)
        } else if selectedMetric == "TX Frames" {
            LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.txFrames))
                .foregroundStyle(.indigo)
        } else if selectedMetric == "RX Frames" {
            LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.rxFrames))
                .foregroundStyle(.brown)
        } else if selectedMetric == "Channel" {
            LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.channel))
                .foregroundStyle(.teal)
        } else if selectedMetric == "Bandwidth" {
            LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.bandwidth))
                .foregroundStyle(.pink)
        } else {
            LineMark(x: .value("X", dataPoint.index), y: .value("Y", dataPoint.defaultValue))
                .foregroundStyle(.gray)
        }
    }
}
```

**Reason:**
To support back-deployment of `@ContentBuilder` in Charts, a compatibility overload of `buildEither` is needed that emits a Charts-specific `BuilderConditional` type. This additional overload degrades the compiler's type-checking performance for branching expressions inside chart builders. When many branches are present, the exponential growth in candidate overloads causes the compiler to exceed its expression complexity limit. This only affects back-deployed configurations (minimum deployment target < OS 27.0) because the compatibility overload is not needed when targeting OS 27.0 or later. Extracting the branching into a dedicated `@ChartContentBuilder` function isolates the type-checking, keeping each expression within the compiler's complexity budget. While typechecking performance is degraded in this particular instance, this tradeoff improves typechecking performance even for projects with lower minimum deployment targets for chart content outside of this case, and for *all* SwiftUI content which imports Charts.