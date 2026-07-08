# Swift Testing Migration

Use Swift Testing for unit and integration tests. XCTest remains for UI tests.

## New tests

New unit and integration tests should:

```swift
import Testing

@Suite
struct ExampleTests {
    @Test
    func computesValue() {
        #expect(1 + 1 == 2)
    }
}
```

Use `try #require(...)` when a value must be unwrapped before continuing.

## XCTest conversion

When touching an existing XCTest unit test, convert in place if the edit naturally crosses that code.

Mapping:

- `XCTestCase` subclass -> `@Suite struct` or `@Suite final class`
- `func testFoo()` -> `@Test func foo()`
- `XCTAssertEqual(a, b)` -> `#expect(a == b)`
- `XCTAssertTrue(condition)` -> `#expect(condition)`
- `XCTUnwrap(value)` -> `try #require(value)`
- `XCTFail("message")` -> `Issue.record("message")`
- `setUp()` -> `init()`
- `tearDown()` -> `deinit`
- async setup -> `async init()`

Do not bulk-rewrite untouched tests just to migrate them.

## Parameterized tests

Prefer:

```swift
@Test(arguments: [
    ("input-a", "output-a"),
    ("input-b", "output-b"),
])
func formats(input: String, expected: String) {
    #expect(format(input) == expected)
}
```

This is clearer than duplicating test methods with copy/paste assertions.

## Parallel execution

Swift Testing runs tests in parallel by default, including across suites. If a suite genuinely needs ordering or guards shared mutable state, use `.serialized`:

```swift
@Suite(.serialized)
struct FileBackedTests { ... }
```

Prefer isolated temp directories and injected dependencies over serialization when practical.

## UI tests

Files under `cmuxUITests/` stay on XCTest/XCUITest. Swift Testing does not support `XCUIApplication` UI testing.
