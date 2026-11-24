# Dev builds are separate

Moved here from the root CLAUDE.md on 2026-11-20 (docs audit); the root keeps a one-line rule.

A tagged dev build (Mac and iPhone) never sees or changes another build's backend data, nor nightly's or stable's,
even when the same person is signed in to all of them. Every dev build sends `X-Cmux-Build-Space: dev:<slug>` (its
tag's slug) to the cloud API and to cmux-mobile-api; nightly and stable send nothing. So anything a dev build stores
in a backend is keyed by its build space: a per-build Durable Object is named `dev:<slug>|<name>` (only through
`spacedEnv` and `envForObject` in `backend/apps/api/src/build-space.ts`), and a per-build Postgres or MySQL row
carries the space and is read filtered by it. Production refuses a dev space (403 `build_space.not_allowed`, the cloud
API and cmux-mobile-api alike), so a dev build pointed at it fails on its first request instead of reaching real data.
Every new Durable Object binding goes in exactly one of `PER_BUILD_BINDINGS` or `ACCOUNT_WIDE_BINDINGS` with the
reason; account-wide is only for what one person shares across builds (team membership, billing, cloud machines).
The pre-push gate's "Build spaces" check (`scripts/cmux-next/check-build-spaces.py`) refuses an unlisted binding and an
object or entry point that reaches objects outside its space. Why: agents dogfood several dev builds at once under the
person's own account, and a build under test must not change what another build, or the person's own nightly, shows.
What does not reach a dev build yet (each lands in nightly's space, because nothing on the request names a build):
provider webhooks (GitHub, Slack, Linear, Google), OAuth completions from the web, invite links and their landing
pages, and inbound texts and email. A dev build's Postgres projection rows go to Postgres only (as the primary, or as
the shadow beside MySQL), never to MySQL; with no Postgres target a dev build's `home.search` finds nothing.
On the Mac a dev build's settings and local state are its own too: `BuildStatePaths` (CmuxNextCompat) keeps its
`cmux-next.json` (with the themes, keybindings, customize, automations and skills beside it), Cloud secrets index and
Keychain service, keys audit, host budget, recovery drafts, agent home, chat uploads and caches under
`~/Library/Application Support/cmux-next/builds/<key>` (caches: `~/Library/Caches/cmux-next/builds/<key>`), starts them
empty (schema defaults plus `SettingsBuildDefaults`, never a copy of nightly's) and names them to its Rust children
through its environment (also its `cmux vm` config, MCP tool lists, mux plugins and classic import folder, which
starts empty: a DEV build never imports the person's classic data); nightly, stable and the other shipped builds keep
`~/.config/cmux`. Its `SettingsBuildDefaults` reach the Rust settings owner as `CMUX_NEXT_SETTINGS_BUILD_DEFAULTS`, and
state named after the bundle id (Chief home, mobile host, Chromium profiles) uses `BuildIdentity.stateFolderName`. The gate's "Dev build state
is its own" check (`scripts/cmux-next/check-dev-build-state.py`) refuses a new shared path without a reviewed row. The dev
sign-in inputs `~/.config/cmux/dev-account` and `~/.secrets/cmuxterm-dev.env` stay shared on purpose.
Sign-in on a Mac dev build (signed NEXT DEV `com.cmuxterm.app.debug.next` included): a dev build never reuses
NIGHTLY's session, in any form. The production cloud-api ignored `X-Cmux-Build-Space` until 2026-11-24 (it refuses it
now), so a dev build on NIGHTLY's session read and wrote NIGHTLY's real data; the separate session stays as the second wall. With a dev account configured (`scripts/setup-team-dev.sh`), the
launch hand-off signs that account in automatically, as the build's own session; otherwise you sign each dev build in
once, in the browser. No build's control socket hands out its session, and `CloudAuthNeverNightlySessionTests` fails
if a dev build's store takes another build's.
