# @Animatable macro

To make the properties of a custom `View` or `Shape` participate in SwiftUI animations, conform such a type to the `Animatable` protocol. Use the `@Animatable` macro to avoid writing out the protocol requirement `animatableData`:

```swift
@Animatable
struct CoolShape: Shape {
    var width: CGFloat
    var angle: Angle
    // ...
}
```

If the property cannot participate in `animatableData`, the `@Animatable` macro will emit an error suggesting marking the property with `@AnimatableIgnored` or conform it to either the `VectorArithmetic` or `Animatable` protocol:

```swift
@Animatable
struct CoolShape: Shape {
    var width: CGFloat
    var angle: Angle
    var isOpaque: Bool // ❌ Cannot automatically synthesize 'animatableData'.
                       // Mark this property with '@AnimatableIgnored'.
                       // Conform the type of this property to 'Animatable' or 'VectorArithmetic'.
}
```

If changes to this property need to be animated, conform its type to either `Animatable` or `VectorArithmetic` protocols. Otherwise, opt-out the property from `animatableData` using `@AnimatableIgnored` macro:

```swift
@Animatable
struct CoolShape: Shape {
    var width: CGFloat
    var angle: Angle
    @AnimatableIgnored var isOpaque: Bool // opt-out the Bool property from 'animatableData'
}
```

# When to implement `animatableData`

Reach for an explicit `animatableData` when the interpolated value needs custom logic that doesn't correspond 1:1 to a stored property, like normalization, clamping, or driving a derived value.

For deployment target >= 26.0, use `AnimatableValues`:

```swift
// A wave shape whose `phase` needs to stay in 0..<2π during animation so
// long-running animations don't accumulate unbounded values, and whose
// `amplitude` must be clamped to `maxAmplitude` on every tick.
struct WaveShape: Shape {
    var amplitude: CGFloat
    var phase: CGFloat
    var maxAmplitude: CGFloat

    var animatableData: AnimatableValues<CGFloat, CGFloat> {
        get { AnimatableValues(amplitude, phase) }
        set {
            amplitude = min(max(newValue.value.0, 0), maxAmplitude)
            phase = newValue.value.1.truncatingRemainder(dividingBy: 2 * .pi)
        }
    }

    // ...
}
```

For earlier deployment targets, use `AnimatablePair`:

```swift
struct WaveShape: Shape {
    var amplitude: CGFloat
    var phase: CGFloat
    var maxAmplitude: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(amplitude, phase) }
        set {
            amplitude = min(max(newValue.first, 0), maxAmplitude)
            phase = newValue.second.truncatingRemainder(dividingBy: 2 * .pi)
        }
    }

    // ...
}
```
