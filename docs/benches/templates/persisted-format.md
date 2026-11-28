# Persisted format: golden round-trip + an old build's file

**Proves:** the next build reads what this build wrote, and what every shipped build wrote. Leo, 2026-11-24:
"we need to make sure in the future these kinds of cutovers always have proper migrations."

**The minimal check:**
1. Register the version constant in `persisted-formats/formats.toml` (app, webviews) or
   `cmux-tui/persisted-formats/formats.toml` (Rust) with `policy = "migrate"` (or `rebuild` + why).
2. Golden round-trip: encode a fixture value, decode it, assert equal; encode again, assert the bytes are stable.
3. Old-reader fixture: `persisted-formats/<name>/v<N>.json`, a file an older build wrote, never edited. The test
   loads every fixture through the real reader (not a copy) and asserts the fields that matter.
4. Bump the version: add `v<N+1>.json` for the current version in the same PR; the old ones stay.
5. `ci/steps.toml` `persisted-formats` (scripts/ci/persisted_formats.py) checks the registry on every PR.

```swift
@Test(arguments: try FileManager.default.contentsOfDirectory(atPath: fixtures))
func readsEveryShippedVersion(_ file: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: fixtures).appending(path: file))
    let state = try WorkspaceStore.decode(data)          // the real reader, migrations included
    #expect(!state.workspaces.isEmpty)
    #expect(try WorkspaceStore.decode(WorkspaceStore.encode(state)) == state)
}
```

Copy from: any `policy = "migrate"` entry in `persisted-formats/formats.toml` and the test it names.
