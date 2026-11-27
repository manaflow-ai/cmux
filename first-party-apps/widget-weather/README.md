# Weather (`cmux/weather`): a widget like Apple's Weather

A `cmux.widget/1` app for the New Tab grid and the sidebar, in Apple's three sizes:

- **Small**: the place (with the location arrow when cmux found it for you), the big current
  temperature, the sky's symbol and words, today's high and low.
- **Medium**: the same at the top, and the next six hours with their symbols and temperatures.
- **Large**: the medium layout, then today and the next five days with range bars over the week.

It is a store app: listed in the App Store and installed with one click, never installed by default
(a `STORE` marker, no `BUNDLED` one; `scripts/cmux-next/sync-app-runtime.sh` copies it to
`Packages/macOS/CmuxNext/Sources/CmuxNextApps/Resources/AppPlatform/store/widget-weather/`). It
imports nothing but `cmux-extension-sdk`.

## Where, what and how often

- **Where.** The place typed in Settings > Apps > Weather (Open-Meteo's geocoder), else the town
  your internet address points to (GeoJS, no account), kept for six hours. So a fresh install shows
  real weather with nothing to set up. cmux has no host location operation yet (CoreLocation with
  the system prompt); when it does, it goes first.
- **What.** Open-Meteo's forecast, no account: the current reading, 24 hours and 7 days, in Celsius
  with the place's local times.
- **How often.** One read per place however many widgets show it. The reading is kept in the app's
  storage, so a new window or a restart draws at once with no read; it is read again at most every
  10 minutes, on the host's 15 minute refresh (`refresh.everySeconds: 900`). Changing units or the
  background reads nothing.
- **Units and clock.** The locale's region decides (Fahrenheit and a 12-hour clock in the US), else,
  for a locale with no region (what hosts send today), the place's country. Units in Settings
  (auto, celsius, fahrenheit) overrides.

## Scopes

| Scope | Why |
| --- | --- |
| `net:api.open-meteo.com` | the forecast |
| `net:geocoding-api.open-meteo.com` | a place you type |
| `net:get.geojs.io` | your town from your internet address, when no place is typed |

Until network access is allowed the widget says so in its frame.

## Settings

`place` (empty: where you are), `units` (`auto`, `celsius`, `fahrenheit`), `look` (`sky`: the sky's
color as in Apple's Weather; `plain`: the theme's background and text).

## Development

```bash
bun cmux-tui/crates/cmux-app-host/tools/pack.ts first-party-apps/widget-weather   # dist/main.js
bun test first-party-apps/widget-weather/test
bun first-party-apps/widget-weather/preview/build.ts                              # preview/scenes.json
scripts/cmux-next/sync-app-runtime.sh                                             # the store copy
cd first-party-apps/widget-weather && cmux ext dev                                # into a running cmux
```

Preview states (`preview/scenes.json`, drawn by the gallery entry `apps.weather-widget`):
`small-clear-day`, `small-clear-night`, `small-plain`, `small-no-network`, `medium-clear-day`,
`medium-rain`, `medium-plain-rain`, `large-clear-night`, `large-snow`. Fixtures are invented
Open-Meteo answers (`preview/fixtures.ts`).

## Gaps

- The web scene renderer has no weather glyphs (its icon pack maps few SF Symbols), so the New Tab
  draws a neutral fallback for the sky symbols; the native sidebar draws the SF Symbols.
- No gradients and no multicolor symbols in the scene: the sky is one color, a lone sun is yellow
  and every other symbol white.
- A store app is unverified, so installing it grants no `net:` scope even though the install sheet
  lists them; the person allows network access in Settings > Apps first.
- The host passes the locale without its region (`en`), so units fall back to the place's country.
