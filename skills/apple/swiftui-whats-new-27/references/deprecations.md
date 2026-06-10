# Deprecations
**SDK Version:** 27.0 and later

APIs hard-deprecated in SDK 27.0. Soft-deprecated APIs are covered by the `swiftui-specialist` skill's `soft-deprecated-apis.md` reference.

## `View.statusBarHidden(_:)` on visionOS → remove

**Platforms:** visionOS

**Issue:**
On visionOS, `statusBarHidden(_:)` is hard-deprecated at version 27.0 and produces a compiler warning:

```
'statusBarHidden' was deprecated in visionOS 27.0: Has no effect on visionOS
```

**Before:**
```swift
struct ImmersiveView: View {
    var body: some View {
        ZStack {
            Color.black
            Text("Immersive Content")
        }
        .statusBarHidden(true)
    }
}
```

**Fix:**
Remove the call entirely — it has no effect on visionOS:

```swift
struct ImmersiveView: View {
    var body: some View {
        ZStack {
            Color.black
            Text("Immersive Content")
        }
    }
}
```

**Reason:**
visionOS does not have a status bar in the iOS sense, so the modifier is a no-op. The deprecation surfaces this so cross-platform code can be cleaned up.
