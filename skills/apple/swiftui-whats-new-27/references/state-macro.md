# @State as Macro
**SDK Version:** 27.0 and later

`@State` has been migrated from a property wrapper to a macro. As a result, you may encounter source incompatibility issues in existing or new code. Here are the issues and how to fix them:

## Init Assignment Errors
**Issue:**
Projects that provide an initial value for a `@State` variable decleration and try to assign its value again in a initializer, before all stored properties are assigned, will encounter errors like:

```
error: Variable 'self.name' used before being initialized
```

For example, this code will fail to compile:
```swift
import SwiftUI

struct ContentView: View {
    var name: String
    @State private var counter: Int = 0

    init(name: String) {
        self.counter = 42
        self.name = name
    }

    var body: some View { Text("\(name): \(counter)") }
}
```

**Fix:**
 Drop the initial value expression at `@State` decleration, only assign it in the init. This ensures the value is correctly initialized.

**Reason:**
The `@State` macro synthesizes real backing storage properties. If your `init` assigns to `@State` properties before other stored properties are set, the compiler catches this as premature `self` usage.

**Warning:**
Assigning a new value to a `@State` property that has an initial value is an anti-pattern and won't produce the expected behavior.

For example, the `body` for the following code will see `0` as the value for `counter`
```swift
struct ContentView: View {
    @State private var counter: Int = 0

    init() {
        self.counter = 42
    }
}
```

## Redeclaration errors with composed property wrappers
**Issue:**
Projects that apply additional property wrappers to properties using `@State` might see errors like:

```
error: invalid redeclaration of synthesized property '_counter'
```

**Fix:**
Refactor the property wrapper composition: remove the redundant wrapper or restructure so backing storage names don't collide. If unsure, ask the user how they prefer to proceed.

**Reason:**
Both the composed property wrapper and the `@State` macro try to synthesize a backing storage property with the same name.

## Private memberwise init not synthesized
**Issue:**
Normally, if a type has only private members, and no explicit initializer, Swift synthesizes a private memberwise `init` that's only accessible in inits defined in extensions of the type. For views with `@State`, this synthesis doesn't occur. This causes an error at the call site when attempting to use the missing `init`:

```
struct Foo: View {
  // all members that would be in the synthesized init are private
  @State private var bar = 0
  private let baz: Int
}

extension Foo {
  init(_ bar: Int, baz: Int) {
    self.init(bar: bar, baz) // error
  }
}
```

**Fix:**
Explicitly define the memberwise initializer instead of relying on the compiler-synthesized one.

**Reason:**
The `@State` macro generates two `init` accessors targeting the same backing property (`__y`) – one on the original property and one on the synthesized `_y` peer – which, per SE-0400, makes the compiler skip memberwise `init` synthesis when multiple `init` accessors target the same stored property.
