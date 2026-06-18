# iOS release notes & "What's New"

How cmux tells iOS TestFlight testers what changed in a build, so an install or
auto-update is never an opaque timestamp.

## The problem

TestFlight shows a build as `MARKETING_VERSION (CURRENT_PROJECT_VERSION)`, e.g.
`1.0.3 (20260613120501)`. The marketing version is human (`X.Y.Z`); the number in
parens is a 14-digit UTC build timestamp, unique and monotonic but unreadable.
With no "What to Test" text, a tester who installs or auto-updates sees only that
timestamp and has no idea what changed. That is the confusion this fixes.

## Source of truth

`ios/CHANGELOG.md`. Newest version on top. Each entry carries two blocks:

- **Internal**: terse, dev-facing, per-build. What changed in THIS build, including
  rough edges and a dogfood-focus line. Pushed on `ship ios` (internal beta).
- **External**: a curated, user-facing summary since the founder's last build. No
  jargon, no PR numbers, no "should fix". Pushed on `ship ios founders`.

Every cut updates this file first (top entry = the build being uploaded).

## Channel 1 — TestFlight "What to Test" (shipped)

After a successful upload, `ios/scripts/upload-testflight.sh` reads the top
`ios/CHANGELOG.md` entry and sets the build's `betaBuildLocalizations.whatsNew`
(en-US) via the App Store Connect API. Internal cut uses the Internal block;
`--external` uses the External block.

Mechanism:

1. `set-testflight-notes.sh` extracts the chosen block's bullets from the top
   entry (awk, stops at the second version heading).
2. `asc_set_testflight_notes.py` mints an ES256 JWT from the ASC API key
   (`ios/Config/AppStoreConnect.local.plist`, key id `4WN4S8ANN4`), resolves the
   app by bundle id, finds the build by CFBundleVersion, then creates or PATCHes
   the en-US `betaBuildLocalizations` with the notes.
3. A just-uploaded build is not addressable until App Store Connect ingests it, so
   the build lookup polls (default 900s, 20s interval). It is non-fatal: the binary
   is already uploaded, and notes can be re-applied later with
   `set-testflight-notes.sh --build-number <n> --audience internal|external`.

This is the per-build text testers see in TestFlight on install and auto-update.

## Channel 2 — in-app "What's New" sheet (PHASE 2, not built)

External/founders testers should also see a "What's New" sheet on first launch
after an update, so the summary reaches them inside the app, not only in
TestFlight (which many testers never read).

Spec for phase 2:

- **Trigger**: on launch, compare the running `CFBundleShortVersionString`
  (MARKETING_VERSION) against the last version the user has seen, persisted in
  `UserDefaults` (e.g. `cmux.whatsNew.lastSeenVersion`). If the running version is
  newer, present the sheet once, then write the running version back. First-ever
  install does NOT show it (seed lastSeenVersion at install so onboarding owns the
  first run).
- **Content source**: the External block of the matching `ios/CHANGELOG.md` entry,
  bundled into the app at build time as a small JSON/plist (a build step parses
  the changelog so the app has no markdown parser). Key by marketing version. If
  there is no entry for the running version, do not show the sheet.
- **UI**: a SwiftUI sheet, title `What's new in <version>`, the External bullets as
  a simple list, one "Got it" dismiss. No network. Localized via
  `Resources/Localizable.xcstrings` (en + ja), matching the repo's localization
  rule. A "What's New" entry in Settings re-opens the latest sheet on demand.
- **Versioning shown**: the sheet shows the marketing version only (`1.0.3`), never
  the build timestamp.
- **Scope**: this is iOS app runtime code, so it requires a tagged dogfood build
  (macOS + simulator + best-effort iPhone) and explicit dogfood approval before
  merge. It is intentionally deferred out of the changelog/scripts PR so that PR
  stays script + docs + skill only and can merge after CI without dogfood.

Follow-up issue should track: the build-time changelog→bundle parse step, the
UserDefaults gate behind a small tested helper (no raw `useEffect`-style launch
side effects scattered in views), the SwiftUI sheet, the Settings re-open entry,
and the localization audit.

## How to cut a release with notes (summary)

1. Edit `ios/CHANGELOG.md`: add the new version as the top entry with an Internal
   and an External block. Never cut a beta without this.
2. `ship ios` (internal) or `ship ios founders` (external). The upload sets the
   matching "What to Test" block automatically.
3. If the notes step warns (build still processing), re-run
   `ios/scripts/set-testflight-notes.sh --build-number <shipped> --audience <a>`
   once it finishes.
