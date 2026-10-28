# Web updates between app updates (web OTA)

A merged change reaches people today only through the Mac nightly: promote, then about 38 minutes of
build, sign, notarize, verify and publish, plus the wait for the next promote. Most GUI work is web
code (the React pages, the agent pane, the webviews app), and none of it needs a Mac build. Web
updates ship that code on its own, signed, minutes after each merge to `feat-cmux-next`.

## Pipeline

1. **Build** (existing, `cmux-next-web-bundle-publish.yml`): each push to `feat-cmux-next` that
   changes a bundle input builds the bundles on Linux and publishes
   `cmux-next-web/<key>/web-bundles-<sha256>.tar.gz` and its `manifest.json` (written last) on
   files.cmux.com. `<key>` is `web-bundle-key.py --source`; the manifest's `outputs` is the
   `--outputs` digest of the unpacked tree.
2. **Pointer** (the `pointer` job): signs `cmux-next-web/ota/every-merge.json`, a pointer to that
   key, with the ed25519 key in the `CMUX_WEB_OTA_SIGNING_KEY` secret of the `artifacts`
   environment. The job runs no bun or node: only this checkout's scripts touch the key. It never
   moves the pointer back (`web-ota-pointer.py newer`: the published pointer's `committed_at` must
   be older), and it verifies what it uploaded.
3. **App** (`WebUpdater` in CmuxNextUpdater, `WebUpdates` in CmuxNextWebUpdates): on NIGHTLY bundles and the tip app only, it
   reads the pointer (a conditional GET: every minute while cmux is in the front, every 10 minutes
   behind other apps, and when it comes to the front a minute or more after the last read), verifies it, downloads and checks the archive, unpacks it into Application
   Support and checks the tree, then serves it from the next safe point.

## The pointer

`scripts/cmux-next/web-ota-pointer.py` makes, signs and checks it. It is an envelope around exact
payload bytes, so neither side canonicalizes JSON:

```json
{"schema": 1, "payload": "<base64 compact JSON>", "signatures": [{"key_id": "e5d7bbcacc70703d", "sig": "<base64>"}]}
```

The payload holds `channel`, `key`, `archive`, `sha256`, `size`, `outputs`, `abi`, `commit`,
`committed_at` and `published_at`. The trusted keys are
`Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json`, which ships in
the app and which CI's sign and verify steps read; `id` is the first 16 hex digits of the key's
SHA-256. To rotate, add the new key, ship it in a nightly, switch the secret, then drop the old key.
A pointer no trusted key covers is replaced by the next publish.

## What the app takes

An update is taken only when all of these hold, in this order, before any download:

- a signature by a trusted key covers the payload, and the payload is well formed for the channel;
- `abi` equals the `abi` of the app's own bundled `pages/web-abi.json` (below);
- `committed_at` is newer than the app's bundled web (the modification time of the app's
  `Info.plist`, which every nightly rewrites, so a Sparkle delta writes it too; it is never before
  the build's commit) and newer than the newest update the app took (`state.json` `floor`). Not
  `web-abi.json`'s: a delta rewrites only changed files, and that file keeps one install's time
  for as long as the abi stays the same.

The archive must then have the pointer's size and SHA-256, and the unpacked tree the pointer's
`outputs` digest (the same algorithm as `web-bundle-key.py --outputs`; `WebUpdateTree`) and `abi`.
A tree is checked against its pointer's digest again at every launch, so a file changed on disk is
never served. The floor stops a replayed old signed pointer from rolling the web back.

Comparing build (or delta install) time with commit time can miss an update (a commit that merged
while the nightly built or before it installed is older than the plist) but never takes an older one. The next merge after the build arrives.

## Native interface (`abi`)

Web bundles call native code by name (page ops, pane methods, scheme paths), so the interface has no
generated contract to hash. `webviews/src/web-abi.json` holds one integer. Bump it in the change
that makes a bundle need native code an older app lacks; web-only changes keep it. A bumped `abi`
waits for the nightly that carries the native side, and the app keeps the web it serves.
`build-pages-web.sh` ships the file as `pages/web-abi.json`, so the app and every update read the
same source.

## Serving and the safe point

`WebBundleOverlay` (CmuxNextPages) maps a bundled root to the same folder inside the active tree.
The bundled folders are registered once at launch: this module's `pages`, the agent pane's
`agent-pane`, and the app's `markdown-viewer/webviews-app`. The page and agent pane scheme handlers
keep validating against their bundled roots and ask the overlay per request, so the web-dev.json
server and overlay (#22664) stay ahead of an update, and an update stays ahead of the bundle.
Pages hosted in Chromium keep their bundled files for now.

A new update never changes what an open page loads: a page's lazy chunks must come from the build
its document came from. `WebUpdates` holds a ready tree as pending and swaps it in at a safe point,
then reloads every page and agent pane the handlers served (`WebBundleServedViews`). The safe
point (`WebSwapGate`, `WebUpdates+SafePoint.swift`) never loses or disturbs what someone is doing:

- no page shows: at once;
- the app has a modal window or sheet open, or is tracking a menu: look again in 15 seconds;
- cmux is in the front: no keyboard, pointer, scroll or click input for 30 seconds (the session's
  `CGEventSource` idle time; no event monitor); behind other apps: 3 seconds after it left;
- then every served page answers `window.cmuxWebSwap.hold()` (`webviews/src/pages/shared/webSwap.ts`,
  installed with the desktop layer) within a second, null when a reload keeps everything it holds.
  It says why not while a component holds it (a prompt the host has not taken, a screenshot being
  read, dictation, shell mode, a new chat's prompt with no chat to keep it, chips the host does not
  hold yet with their contents, a draft acpmux does not hold yet, a transcript place not reported
  yet), while an input method composes, while text is selected, while a field has the keyboard that
  does not take it back (the composer does) or its caret is before the end, while a menu, popover
  or dialog is open, or while a scroller other than the transcript is away from its start. A page
  that does not answer is busy.

Any wait looks again in 15 seconds (one DemandTimer, `web-updates.safe-point`, which stops once
nothing is pending); `updates.web.status` `waiting_for` names the last reason. A reload keeps a
composer draft (the composer writes every change to the pane origin's `localStorage` at once and to
acpmux, `composerDraft.ts`), its chips (the host's `chat.draftAttachments`, `keptAttachments.ts`)
and the transcript's place (`chat.scrollAnchor`), and reads them back on load.
Web updates start when the app first reads `updates.*`. From then until the check of the kept tree ends, requests wait for it. A page that loaded before that keeps the bundled web until the next safe point. A tree is pruned only once nothing serves it.

## Setting and controls

`updates.web` in cmux.json (Settings > Updates, "Web UI Updates"): `every-merge` (default),
`nightly` or `off`. Off returns to the bundled web at the next safe point, and at launch it serves
the bundled web before any page loads. Switching to the other channel returns to the bundled web
until that channel has an update newer than the last one taken. Only NIGHTLY bundles
(`com.cmuxterm.app.nightly[.<tag>]`) and the tip app (cmux NEXT DEV with the tip feed stamped in,
`UpdateBuildIdentity.isTipBuild`) take web updates: another Debug or DEV build keeps the developer's own web,
and Release and RC builds the web they were built with. Downloads follow `updates.meteredNetwork`
(Low Data Mode and expensive links through `URLRequest`). A failed download is tried again at the
next check: the pointer's ETag is kept only once it was taken or refused for good.

- `updates.web.status`: channel, phase, the active and previous updates, what is served now and what
  is pending, the bundled `abi`, the last check and why the newest pointer was not taken.
- `updates.web.check`: reads the pointer now.
- `updates.web.rollback`: serves the previous update (the bundled web when none) at the next safe
  point. The rolled-back update is not taken again; the next newer one is.
- `updates.web.apply`: swaps a pending update in now.

The Settings card with the current version and a one-click roll back reads these methods (a
follow-up).

## Not yet

- **Nightly channel**: `ota/nightly.json` is read but nothing writes it. The nightly train would
  sign it for the promoted commit's key with the same script. The release-rings lane owns
  `updates.channel`; the `updates.web` default will follow it (dev to every merge, stable to off).
- **Signing key custody**: the private key exists only in the `CMUX_WEB_OTA_SIGNING_KEY` secret
  (no backup; losing it costs one nightly without web updates, never trust). Rotate, as above, to a
  key generated where the Sparkle and notary keys are kept, once that place is named.
- **Push hint**: the app polls a small cached file. A push (the existing notification path, or a
  long poll on a presence worker) can call `updates.web.check` instead.

## Phase 2: peer seeding (design only)

Archives are content addressed (`web-bundles-<sha256>.tar.gz`) and the signed pointer names that
digest, so any peer can serve the bytes and the app only trusts the signature. The plan reuses the
iroh stack that already links machines (cmux-tui's iroh transport, `iroh-release-gate.yml`):

1. Each machine that took an update keeps its archive (`web-updates/archives/<sha256>`) beside the tree
   and offers it as an iroh-blobs entry under its BLAKE3 hash; the pointer gains a `blake3` field
   (signed) so the hash names the blob without trusting the peer.
2. The app reads the pointer from files.cmux.com as now (it is small and must be fresh). For the
   archive it asks the user's own machines first (the machine mesh already lists them and their
   iroh node ids), then fleet hosts that keep the newest archives, then files.cmux.com. iroh-blobs
   verifies each chunk with BLAKE3 while it streams, and the SHA-256 check above still runs on the
   whole file.
3. Fleet hosts that build the bundles seed them as soon as they are built, before R2 upload
   completes, so machines on the tailnet get an update without leaving it.

Nothing about trust changes: a peer can only offer bytes whose digest the signed pointer already
names. A peer that serves wrong bytes fails the check and is skipped for that update.
