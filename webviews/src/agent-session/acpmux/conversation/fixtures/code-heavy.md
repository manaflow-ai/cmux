I found the bug: `parseRange` treats an empty end as `0`, so `--range 5:` selects nothing.

```ts
export function parseRange(input: string): { start: number; end: number | null } {
  const [start, end] = input.split(":");
  return { start: Number(start), end: end === "" ? null : Number(end) };
}
```

The test that caught it:

```swift
func testOpenEndedRange() throws {
    let range = try Range(parsing: "5:")
    XCTAssertEqual(range.start, 5)
    XCTAssertNil(range.end)
}
```

Run it with:

```bash
bun test src/range.test.ts --filter "open-ended"
```

And the diff:

```diff
-  return { start: Number(start), end: Number(end) };
+  return { start: Number(start), end: end === "" ? null : Number(end) };
```

```
plain output with no language
  indented line
```
