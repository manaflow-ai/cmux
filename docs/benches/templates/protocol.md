# Protocol / contract: one fixture, both sides

**Proves:** what one side writes, the other reads, across versions: the daemon and the pane, the Mac and the phone,
the backend and the app. Drift shows up as a failing fixture in the PR that caused it, not as a blank pane later.

**The minimal check:**
1. Keep golden messages as files beside the schema (`<protocol>/fixtures/<message>.v<N>.json`), one per message
   kind and version, never edited once shipped.
2. Producer side: encode a known value; assert it equals the fixture byte for byte (or after canonical JSON).
3. Consumer side (the other language): decode every fixture; assert the fields; re-encode and compare.
4. Unknown fields: decode a fixture with an extra field; the reader must keep working (forward compatibility).
5. Both sides' tests run when either side's paths change: list both in the area's `tests` in relevance-map.toml.

```rust
#[test]
fn fixtures_round_trip() {
    for f in std::fs::read_dir("fixtures").unwrap() {
        let bytes = std::fs::read(f.unwrap().path()).unwrap();
        let msg: Message = serde_json::from_slice(&bytes).unwrap();
        let again = serde_json::to_value(&msg).unwrap();
        assert_eq!(again, serde_json::from_slice::<serde_json::Value>(&bytes).unwrap());
    }
}
```

```ts
import { readdirSync, readFileSync } from "node:fs";
test.each(readdirSync(FIXTURES))("decodes %s", (name) => {
  const raw = JSON.parse(readFileSync(`${FIXTURES}/${name}`, "utf8"));
  expect(encode(decode(raw))).toEqual(raw);
});
```

Copy from: `cmux-tui/crates/cmux-pane-protocol` and its generated `webviews/src/protocol` (`bun run protocol:codegen`).
