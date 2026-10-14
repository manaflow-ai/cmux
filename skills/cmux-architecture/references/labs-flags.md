# Labs flags (cmux NEXT)

New UI looks and behaviors land behind a Labs flag that the team turns on. They don't go into the defaults. One registry serves Settings, the palette, cmux.json, MDM, Swift and web. No need to ask anyone before adding a flag.

## Add a flag

1. Add a row to the `labs` list in `schemas/settings/source/labs.json`, then run `python3 scripts/cmux-next/gen-settings-sources.py`. The row needs:
   - `key`: `labs.<name>`, where `<name>` is lowerCamel.
   - `owner`: your lane or your name.
   - `created`: today's date.
   - `expires`: about 14 days later.
   - `cohort`:
     - `off`: nobody has it until they turn it on. This is the usual choice.
     - `nightly-next`: on in nightly and dev builds.
     - `default`: promoted. Only a promotion PR sets this.
   - `default`: `true` only when the cohort is `default`.
   - `kind`: `toggle`.
   - `title`: the Settings label, keyed as `settings.labs.<name>`.
   - `help`: the one-line intent, keyed as `settings.labs.<name>.help`. Settings shows it, and the `LabsFlag` registry carries it.
   - `keywords`.
2. Add the two strings to `Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Localizable.xcstrings` in every locale (see the cmux-localization skill).
3. Regenerate the settings exports on the current base. Use the fleet's exclusive class with `scripts/measure/export-settings-artifacts.sh`. This updates the settings schema, the MDM manifest and the defaults snapshot.
4. Read the flag only through its helper:
   - **Swift:** `settings.snapshot.lab(.name)`. Observe it with `ObservationStream({ settings.snapshot.lab(.name) })`.
   - **Web:** `useLabsFlag("name")` in a component, or `labsFlag("name")` once, from `webviews/src/experiments/labs.ts`. Every `PageWebView` page, the agent pane and New Tab included, gets `data-labs` on `<html>`. `labsTeamBuild()` says whether this is a nightly or dev build (`data-labs-team`).

The flag then shows up in these places without further work:
- Settings > Experimental > Labs, as a toggle with its intent line.
- The palette's settings scope: type `, <title>` and flip it.
- Help > Feature Flags.
- The New Tab page's Labs section, in nightly and dev builds only: the intent line and a toggle, with All Labs… for Settings.
- cmux.json and MDM, as `labs.<name>`.
- Agents, which may set it.

## Promote, extend or delete

- **Promote:** a one-line PR that sets `cohort` to `default` and `default` to `true`. That PR is the design call: label it `needs a call` and link the dogfood.
- **Extend:** move `expires` forward and say why in the PR.
- **Delete:** remove the row and the code path that loses. Add the key to `schemas/settings/retired-keys.json` so an old cmux.json still loads cleanly.

`gen-settings-sources.py` prints `warning: labs.<name> ... expired` for every flag past its `expires`, including under `--check` in CI. The warning never fails the run, so the owner has to act on it.

## Labs or an experiment?

| | Labs flag | Experiment (`webviews/src/experiments/experiment.ts`) | Classic `CmuxFeatureFlags` |
|---|---|---|---|
| Who chooses | a person, in the shipped NEXT app | a developer, in the gallery | PostHog, remotely |
| What it holds | on or off | one arm of several | remote rollout |
| Use for | opt-in looks and behaviors | comparing implementations before picking one | classic only |
