# cmux iOS changelog

Single source of truth for what each cmux iOS TestFlight build changed. Every
beta cut updates this file FIRST (top entry = the build you are about to upload),
and the upload pushes the top entry's notes to TestFlight "What to Test" so the
build is no longer an opaque timestamp on install or auto-update.

## How testers see a build

TestFlight shows each build as `MARKETING_VERSION (CURRENT_PROJECT_VERSION)`, for
example `1.0.3 (20260613120501)`. `MARKETING_VERSION` is the human version
(`ios/Config/Shared.xcconfig`, semver `X.Y.Z`); the number in parens is the build
id, a 14-digit UTC timestamp stamped at upload time (unique and monotonic, but not
meant to be read). Testers should track the marketing version; the timestamp only
distinguishes rapid internal iterations of the same version.

Two audiences, two notes per entry:

- **Internal** (`ship ios`, the `cmux beta` group): terse, dev-facing, per-build.
  Lists what changed in THIS build, including rough edges, so internal dogfood
  knows what to hit. Pushed to "What to Test" on every internal cut.
- **External / founders** (`ship ios founders`): a curated, user-facing summary of
  what is new since the founder's last build. No internal jargon, no "should fix",
  no PR numbers. Pushed to "What to Test" on external cuts.

The upload script (`ios/scripts/upload-testflight.sh`) reads the matching block
from the top entry and sets the build's `betaBuildLocalizations` whatsNew (en-US)
via the App Store Connect API after the upload processes. Internal cut uses the
Internal block; `--external` uses the External block.

Phase 2 (not built yet): external/founders builds also get an in-app "What's New"
sheet on first launch after an update, sourced from the External block. Spec in
`docs/ios-release-notes.md`.

Keep entries short. No fluff, no AI rhetorical patterns, no em dashes (repo rule).
Newest version on top.

The top entry's version MUST equal the checked-in `MARKETING_VERSION` in
`ios/Config/Shared.xcconfig`. `upload-testflight.sh` enforces this before upload
(it refuses to attach notes for a different version), so bump the version with
`ios/scripts/bump-ios-version.sh` in the SAME change that adds the top entry.

---

## [1.0.3] - 2026-06-13

### Internal

- Disconnected "Your Computers" screen rebuilt: coalesced one-row-per-Mac list (no more duplicate dev-build pills), online/last-seen status, tap to reconnect with spinner and failure alert, swipe to remove.
- Composer: iMessage-style terminal composer, open by default, inline send, drafts saved per terminal (#5876).
- View as Text sheet for copy-pasting raw terminal output (#5875).
- Pairing QR is now minimal and full-width (routes-only payload, Copy IP/Port, no expiry); scans faster (#5872, #5727).
- Notifications forward to the phone only while you are away from the Mac (#5912); push tap deep-links to the right workspace once it can be navigated to (#5927); cross-device dismiss-sync with an authoritative unread badge (#5916).
- Sign-out is local-first and works offline; revocation is best-effort and bounded (#5776).
- Workspace list: groups, unread dots, last-activity previews, shared Unread filter (#5726).
- Watchdog fix: render-grid liveness probes before teardown, fixing a false-fire replay loop (#5869).
- iroh mobile transport is enabled on release iOS builds with EndpointId pinning. What to test: pair a new cmuxRelay Mac over iroh on a release build, then rotate/reset the Mac identity and confirm the phone shows the re-trust prompt instead of connecting silently.
- Terminal fills its full height again after closing the keyboard: viewport reports are now serialized and stale echoes dropped, so a late keyboard-up reply can no longer pin the grid small and leave permanent empty space above a TUI (opencode top-gap bug).
- Terminal stretches to fill the phone when the Mac window is the row constraint: the rendered font auto-fits to the granted grid (never below your chosen size), and reports keep advertising base-font capacity so the grid recovers when the Mac window grows.
- Dogfood focus: hit the composer (send + drafts), View as Text, pair a Mac via the new QR, lock the phone and confirm a forwarded notification taps through to the right workspace, sign out with airplane mode on. Also open a full-screen TUI, open/close the keyboard rapidly a few times, and confirm no dead band stays above the content.

### External

- The reconnect screen now shows each of your computers once, with online status and last-seen time. Tap to reconnect, swipe to remove.
- New terminal composer: type and send like a message, with drafts saved per terminal.
- View as Text: copy raw terminal output from a clean sheet.
- Faster, simpler Mac pairing QR, with Copy IP/Port if scanning is awkward.
- Mac pairing now works over the cmux relay transport on release builds, and the phone asks before trusting a Mac whose secure identity changed.
- Smarter notifications: your phone only buzzes when you are away from your Mac, tapping a notification opens the right workspace, and unread state stays in sync across devices.
- Sign-out now works offline.
- Polished workspace list with groups, unread dots, and recent-activity previews.

## [1.0.2] - 2026-06-10

### Internal

- Mobile terminal foundation: faithful render-grid replay over the cmux SPM core (#5079).
- Multi-Mac host switcher with a hierarchical device tree; workspaces from all Mac windows; rename and pin from the phone (#5513, #5648, #5565, #5512).
- Customizable terminal toolbar: data-driven custom actions, reorderable built-ins, redesigned default layout (#5510, #5532, #5579).
- Paste images from the phone clipboard into the terminal (#5546).
- First-run onboarding, Tailscale-off detection, actionable pairing failures, cancellable sign-in, pull-to-refresh on the workspace list (#5655, #5714, #5722, #5713, #5728, #5654).
- Pairing window shows a connected state when the phone attaches; QR slimmed v1 (#5542, #5727).
- Early browser panes (WKWebView) and a Send Feedback flow (#5652, #5653).

### External

- Mobile terminal: drive your Mac's cmux terminals from your phone.
- Switch between multiple Macs, see workspaces from every window, and rename or pin from the phone.
- Customizable terminal toolbar with your own actions.
- Paste images straight from the phone clipboard.
- Smoother first run: onboarding, clearer pairing errors, and pull-to-refresh.
