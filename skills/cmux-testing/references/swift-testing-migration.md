# Swift Testing Migration

Swift Testing for unit and integration tests; XCTest stays for UI tests under `cmuxUITests/` (Swift Testing has no `XCUIApplication` support).

## New tests

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

## XCTest conversion mapping

Convert in place only when an edit naturally crosses the file; do not bulk-rewrite untouched tests.

| XCTest | Swift Testing |
|---|---|
| `XCTestCase` subclass | `@Suite struct` (or `@Suite final class` for a reference type) |
| `func testFoo()` | `@Test func foo()` |
| `XCTAssertEqual(a, b)` | `#expect(a == b)` |
| `XCTAssertTrue(cond)` | `#expect(cond)` |
| `XCTUnwrap(x)` | `try #require(x)` |
| `XCTFail("msg")` | `Issue.record("msg")` |
| `setUp()` | `init()` (async setup: `async init()`) |
| `tearDown()` | `deinit` |

## Parameterized tests

```swift
@Test(arguments: [
    ("input-a", "output-a"),
    ("input-b", "output-b"),
])
func formats(input: String, expected: String) {
    #expect(format(input) == expected)
}
```

## Parallel execution

Tests run in parallel by default, including across suites. Prefer isolated temp directories and injected dependencies; use `@Suite(.serialized)` only when a suite genuinely needs ordering or guards shared mutable state.
