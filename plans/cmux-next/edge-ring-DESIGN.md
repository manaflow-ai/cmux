# Edge ring: every merge on every teammate's Mac, and builds shared between Macs

Leo-ask: ask-086fe433a1. Leo, 2026-10-21: "could we potentially have a hot reload, like bypassing the
publish route? ... just have the nightly without needing it to be the published, notarized fully
nightly ... constantly grab the latest main whenever something of that builds ... seed the main ...
the whole torrenting thing".

Status: design, 2026-10-22. Builds on the release rings (Stable, Nightly, Canary, Dev; #23835,
#23845) and the canary (#23852).

## Where we are

- **Every app build is notarized and published by `nightly.yml`.** It builds on the dedicated
  builder Mac (cmux22) and signs, notarizes and publishes on hosted runners. Push to publish takes
  about 43 min, measured on 2026-10-20 (`nightly-builder-DESIGN.md`):

  | Step | Time |
  | --- | --- |
  | helper | 7 min |
  | app | 11 min |
  | variant | 5 min |
  | sign and notarize | 15 min |
  | verify | 3 min |
  | publish | 2 min |

  Builds coalesce: one runs, at most one waits, and the newest head goes next.
- **Dev ring** (`NIGHTLY_NEXT_DEV_RING=on` since 2026-10-21 23:49Z). Each build is published as
  `cmux-next-dev` and moves to `cmux-next` (Nightly) when the scheduled canary passes it.
- **Switching rings in Settings > Updates** checks the new ring at once. Going back to a slower ring
  restarts once into the build this Mac kept.

So today "the latest" is about 45 min behind a merge. Notarization alone is a third of that, and a
build that fails the canary never reaches Nightly.

## Part 1: the Edge ring (signed, not notarized)

**What a person sees.** Settings > Updates > Channel gets a fifth value, **Edge**: "every merge,
signed but not notarized, for the team". It is off by default, offered only on team builds
(below), and the same one-restart update as every other ring. Going back is the Go Back from
#23845, into the kept Dev or Nightly build.

**Why no notarization works for updates.** Gatekeeper's notarization check runs on a
**quarantined** app: one downloaded by a browser, Mail or AirDrop. Sparkle downloads the archive
itself, checks its EdDSA signature against the app's `SUPublicEDKey`, and installs it without
quarantine, so an update never goes through the notarization check. The code signature still has
to be valid Developer ID: the app's launch constraints, its keychain access groups and
`UpdateDropBack.signingTeam` all need it.

This is the one assumption to prove first (step E0 below): an unnotarized, Developer ID signed build,
installed by Sparkle over a notarized one on macOS 14 and on the newest macOS, launches with no
prompt. If it does not, Edge falls back to notarizing in parallel (below).

**Build and publish.**
- **Trigger and coalescing.** The same trigger as the nightly: `promote-nightly-next` moves
  `nightly-next` on every green Release compile of `feat-cmux-next`. No clock, no new queue.
- **Publish while notarizing.** `build-sign-notarize-nightly` already uploads the signed,
  unnotarized app (`cmux-nightly-signed-unnotarized-<variant>`). It also starts the signed-app checks
  while notarization runs ("Start the signed-app checks (they run during notarization)"). A new
  `publish-edge` job publishes that artifact to the Edge feed as soon as those checks pass, about
  25 min after the push instead of 43. The run then goes on exactly as today: notarize, verify,
  publish to the Dev feed, canary, promote to Nightly. So Edge adds no build: it publishes the same
  build earlier.
- **A separate feed, not a new channel tag.** The Edge feed is `nightly-next/edge/appcast-arm64.xml`.
  An Edge Mac reads it through the updater's existing feed override (`UpdateController.feedOverride`,
  today used for test feeds). Every other Mac never fetches it, so no older app can see an
  unnotarized item whatever its channel filter, and the `cmux-next` feed guard stays unchanged.
- **What the Edge feed holds.** Only signed builds of the current train: the newest 10, each with
  its EdDSA signature and `sparkle:version`. A build pulled from the main feed is pulled from Edge
  too (the same `pulled.json`).

**The verification gate stays in front.** No build reaches a teammate unchecked:
- **Before Edge (new gate on an existing check):** the signed-app checks that already run during
  notarization (`Verify signed nightly app`: socket, window, New Tab, an agent prompt, 60 s with no
  crash) must pass before `publish-edge` runs. They are the canary's own checks. On the same hosted
  image they passed with the socket up in about 5–7 s (run 39680012953).
- **Before Nightly (unchanged):** the scheduled canary on the notarized DMG, and promotion by its
  verdict.
- **Pulls (unchanged):** a fail pulls the build from every feed, and the pulled-build banner offers
  Go Back on Edge as on Nightly.

**Who can pick Edge.** Edge is a team ring. The row shows it only when the app is a team build
(the Debug Settings toggle `updates.edgeRing`, default off), so a public user never sees an
unnotarized option. This is the risk:high default-off rule.

**If E0 fails (a prompt or a refusal).** Notarize in parallel: publish to Edge when `notarytool
submit --wait` returns, skipping the stapling and the DMG round. That would be about 30 min after the
push, not 43. The rest of this design is unchanged.

## Part 2: sharing builds between team Macs (seeding)

**Goal.** A new build reaches every team Mac from the nearest Mac that already has it, so the first
Mac on the tailnet to download it serves the rest, and R2 stays the fallback. One Sparkle archive is
about 225 MB with Chromium. Ten Macs times one build per 25 minutes is about 5 GB an hour from R2 that
the office LAN could serve instead.

**Content addressing.** The Edge feed's enclosure for each build carries, beside the URL and the
EdDSA signature, the archive's BLAKE3 hash (`cmux:blake3`, an extra attribute Sparkle ignores). A Mac
fetches by hash and checks the hash. Sparkle then checks the EdDSA signature as always, so a
peer cannot hand over a different build: the worst a bad peer does is waste a download.

**Transport: iroh.** cmux already links iroh (`cmux-tui`, `cmux-app-ffi`, the managed relay
catalog). The daemon gets an `iroh-blobs` store for update archives:
- **Serving.** After an update is staged, the daemon adds the archive to the store and announces
  the hash. It serves only hashes listed in the current Edge or Dev feed, and only to this Mac's
  team peers (P1 decides the list: the tailnet's team devices, or the cmux account's team), never to
  the internet at large.
- **Fetching.** Before Sparkle downloads, the updater asks the daemon for the hash with a deadline
  (30 s to first byte). The daemon fetches from peers in parallel ranges (BitTorrent's swarm, done by
  iroh-blobs' verified streaming). On success Sparkle's download URL for that item is the daemon's
  `localhost` file. On a miss or a timeout it is the R2 URL as today.
- **The fleet seeds.** The builder Mac (cmux22) and one always-on capture mini seed every new build
  as soon as it is published, so the first teammate's download is already peer-served on the
  tailnet.

**What it does not do.** No peer is ever trusted for content: the hash and the EdDSA signature
decide. Nothing changes for public Nightly and Stable users. Seeding is a team feature, off unless
Edge or `updates.seedBuilds` (team, default on for team builds) is on.

## Steps (one small PR each)

| Step | PR | Proves or ships |
| --- | --- | --- |
| E0 | Fleet probe: install an unnotarized Developer ID build by Sparkle over a notarized one on two macOS versions; launch, socket, no prompt | the assumption Part 1 rests on |
| E1 | `scripts/ci/edge_feed.py`: compose the Edge appcast from a signed build (newest 10, EdDSA signature and version required, pulled builds dropped), with tests | the feed shape (first code PR) |
| E2 | `nightly.yml`: `publish-edge`, gated on the signed-app checks, publishing the signed unnotarized artifact (behind `NIGHTLY_NEXT_EDGE_RING`, default off) | Edge builds ~25 min after a push |
| E3 | App: the Edge ring value (Debug toggle `updates.edgeRing`), feed override to the Edge feed, Go Back to the kept Dev/Nightly build | teammates roll to Edge in place |
| P1 | Edge feed carries `cmux:blake3`; the daemon's update-archive store serves staged archives to team peers | seeding |
| P2 | The updater fetches through the daemon (peers first, 30 s deadline, R2 fallback); cmux22 seeds | peer downloads |

## Open questions

1. E0's result decides between "publish before notarizing" and "publish when notarization returns".
2. A team build: the Debug toggle is the gate today. If team membership should come from the
   account instead (cmux Cloud team), E3 reads it there.
3. The Edge feed keeps 10 builds. If Go Back should reach further, raise it; each item is metadata
   only, and the archives stay wherever R2 keeps nightly archives.
