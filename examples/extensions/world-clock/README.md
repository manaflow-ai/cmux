# World clock: the time in the places you work with

`local/showcase-world-clock` imports nothing but `cmux-extension-sdk`. A sidebar section lists a
row per time zone: the city, its time, how far it is from you and its zone's abbreviation, and
Tomorrow or Yesterday when its day is not yours.

- **The zones are a setting**: Settings > Apps > World clock > Time zones, IANA names separated by
  commas (`America/Los_Angeles, Europe/London, Asia/Tokyo`). A 12-hour clock is another setting.
- **The zone rules come from cmux.** Extensions run in a sandbox without `Intl`, so
  `cmux.time.zone(name, at)` answers the offset and abbreviation from cmux's own time zone data.
- **It costs nothing.** One timer per view, just after each minute starts; no reads at all.

## Run it

```sh
cd examples/extensions/world-clock
cmux ext dev
```

`cmux ext dev` packs `src/main.ts` into `dist/main.js` (build output, not committed). Tests:
`cmux-tui/crates/cmux-app-host/js/test/world-clock.test.ts` packs it and runs it in the fake
host.
