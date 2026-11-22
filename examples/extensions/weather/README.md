# Weather: the current conditions for a place you choose

`local/showcase-weather` imports nothing but `cmux-extension-sdk`. A sidebar section shows the
temperature, the sky, what it feels like, today's high and low and the wind for one place.

- **The place is a setting.** Type a city in the section, or set Place (and Units) in Settings >
  Apps > Weather; both write the same setting.
- **It needs network access.** Open-Meteo answers with no account or key. Turn on its two hosts
  (`net:geocoding-api.open-meteo.com`, `net:api.open-meteo.com`) in Settings > Apps; until then the
  section says so.
- **It reads little.** Once when the place or units change, then every 15 minutes. Several windows
  share one read.

Right-click the section to refresh it or change the place.

## Run it

```sh
cd examples/extensions/weather
cmux ext dev            # loads it into the running cmux; every save reloads it
```

`cmux ext dev` packs `src/main.ts` into `dist/main.js` (build output, not committed). Outside
this repository, copy the folder and run `npm install` first; inside it, `tsconfig.json` points
the import at the SDK's source. Tests:
`cmux-tui/crates/cmux-app-host/js/test/showcase-examples.test.ts` packs each sample and runs it
in the fake host.
