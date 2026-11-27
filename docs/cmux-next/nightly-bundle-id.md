# cmux-next nightly bundle ID

cmux-next nightlies ship as **cmux NIGHTLY** (`com.cmuxterm.app.nightly`). They do
not ship as cmux NEXT (`com.cmuxterm.app.nightly.cmux-next`) (user msg 20276,
2026-11-03).

## Downloads

| Link | What it serves |
| --- | --- |
| [cmux.com/next](https://cmux.com/next) | `releases/download/nightly-next/cmux-nightly-next-macos-arm64.dmg` |
| `nightly-next/cmux-nightly-next-macos-arm64.dmg` (rolling) | The newest cmux NIGHTLY-identity build. Only `publish-nightly-identity-legacy` writes it, after the feed names that build |
| `nightly-next/cmux-nightly-next-macos-nightlyid-arm64-<build>.dmg` | That build, immutable |
| Feed | `https://files-next.cmux.com/nightly-next/appcast-arm64.xml` |

The release body of the `nightly-next` release names cmux NIGHTLY and
`com.cmuxterm.app.nightly`. It links the rolling DMG.

## Moving from a cmux NEXT install

A cmux NEXT app (`com.cmuxterm.app.nightly.cmux-next`) keeps its own data. A
cmux NIGHTLY install does not read that data, and nothing merges it on its own:
a merge into a NIGHTLY home that already holds data could overwrite chats.

| Data | cmux NEXT location | cmux NIGHTLY location |
| --- | --- | --- |
| Preferences | `~/Library/Preferences/com.cmuxterm.app.nightly.cmux-next.plist` | `~/Library/Preferences/com.cmuxterm.app.nightly.plist` |
| Chief memory | `~/.cmux/chief/com.cmuxterm.app.nightly.cmux-next` | `~/.cmux/chief/default` (shared root) |
| Agent sessions (acpmux) | `~/.acpmux/builds/<cmux NEXT key>` | the shared acpmux home |
| Socket | `/tmp/cmux-nightly-cmux-next.sock` | `/tmp/cmux-nightly.sock` |

To move:

1. Download cmux.com/next and install cmux NIGHTLY.
2. Keep cmux NEXT.app until you have the chats you need. The two apps can be
   open at the same time.
3. When nothing in cmux NEXT is needed, delete `cmux NEXT.app`. The data above
   stays on disk until you delete it.

The old cmux NEXT feed (`/nightly-next/next/`) still gets builds while the
pipeline builds the cmux NEXT DMG as the input of the NIGHTLY copy. It stops
when that step is removed (below).

## Still open

- `nightly.yml` still signs and notarizes each build as cmux NEXT first, then
  re-signs it as cmux NIGHTLY (`scripts/ci/nightly-next-legacy-identity.sh`).
  That is two notarizations per build. The next step signs once, as cmux
  NIGHTLY, and removes the cmux NEXT identity from `decide`,
  `verify-app-bundle-channel-metadata.sh` and the updater's `nightlyNext` track.
- cmux NEXT Stable (`stable-next.yml`) still uses
  `com.cmuxterm.app.nightly.cmux-next-stable`. The plan moves it to
  `com.cmuxterm.app`. That needs the RELEASE provisioning profile in the
  `stable-next` sign job.
