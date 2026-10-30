# Getting cmux-next

cmux-next is the rewrite of cmux on the `feat-cmux-next` branch: a Swift shell, the Rust core in
`cmux-tui`, and the React webviews. There are two channels you can run today.

| Channel | Who it's for | App | Bundle id | Updates |
|---|---|---|---|---|
| **cmux NEXT DEV** | Daily dogfood, runs beside classic | `cmux NEXT DEV.app` | `com.cmuxterm.app.debug.next` | Rebuilt after each green `feat-cmux-next` push; update with one command |
| **nightly-next** | The future nightly; *replaces* classic cmux NIGHTLY | `cmux NIGHTLY.app` | `com.cmuxterm.app.nightly` (same as classic nightly) | Sparkle, about every 30-60 min, Apple Silicon only |

Pick DEV if you also want to keep classic NIGHTLY. Pick nightly-next only if you're ready for it
to take classic NIGHTLY's place, because both use the same bundle id and socket.

## cmux NEXT DEV

The install script is on the `feat-cmux-next` branch, not on `main`. You don't need a checkout:

```sh
curl -fsSL -o /tmp/update-dev-daily.sh \
  https://raw.githubusercontent.com/manaflow-ai/cmux/feat-cmux-next/scripts/cmux-next/update-dev-daily.sh
bash /tmp/update-dev-daily.sh            # installs or updates ~/Applications/cmux NEXT DEV.app
```

From a `feat-cmux-next` checkout, run `bash scripts/cmux-next/update-dev-daily.sh` instead.
The first install opens the app. Later, open it from `~/Applications` or Spotlight
("cmux NEXT DEV").

Run it whenever you want the latest build. When the published build is the one you have, it
says so and leaves the app alone. Otherwise it downloads `cmux-NEXT-DEV.zip` from the
`cmux-next-dev` prerelease, checks its SHA-256 and bundle id, quits the app keeping its sessions,
swaps the app in place and opens it again: terminals, agents and chats come back by themselves.
It's signed but not notarized, so the script downloads it outside the browser's quarantine.
Details are in [dev-daily.md](dev-daily.md).

To see how fresh it is, look at the asset's upload time, not the release date (the release
entry keeps its creation date):

```sh
gh api repos/manaflow-ai/cmux/releases/tags/cmux-next-dev -q '.assets[] | "\(.name) \(.updated_at)"'
```

## nightly-next

- **Download (Apple Silicon):** the newest DMG is on the `nightly-next` GitHub prerelease:
  `gh release download nightly-next -R manaflow-ai/cmux -p '*macos-arm64*.dmg'`
- **Update feed:** `https://files-next.cmux.com/nightly-next/appcast-arm64.xml`. Installed apps
  move to this feed on their own. The older `appcast.xml` and `appcast-universal.xml` stopped
  changing on 2026-10-07, when nightly-next went Apple Silicon only, so don't judge freshness
  by them.
- **Notarization:** nightly-next is notarized. If Apple's notary service stalls, the nightly
  workflow fails and recovers by itself (`recover-nightly-next-notarization`), and the feed just
  stays on the last good build. Use DEV meanwhile.

## Your sessions survive updates

The terminal daemon outlives the app. An update (Sparkle or the DEV script) quits the app,
swaps it, and relaunches it. The new build takes over the running terminals, so shells,
scrollback and running agent turns keep going. Screens also come back after a reboot.

To go back one build: palette **Roll Back to Previous Version**, or `cmux update rollback`.
It's refused, with a message, when the newer build has already changed stored data that the
older one can't read.

## Coming from classic

In cmux-next, open the command palette (⇧⌘P) and run **Import Workspaces from Classic cmux**, or
run `cmux workspace import-classic`. It reads classic's last saved session without changing it and
opens its workspaces with their panes and tabs. A terminal that ran Claude Code or Codex usually
comes back as a chat that resumes its session. A toast says when it's done and what stayed in
classic. [classic-to-next.md](classic-to-next.md) lists exactly what comes over, and has an agent
playbook for choosing workspaces or bringing launch commands too.

## Settings in your dotfiles

Settings live in `~/.config/cmux/cmux-next.json` and key bindings in
`~/.config/cmux/keybindings.json`. Both reload when you save and keep your comments when
Settings writes to them. [dotfiles.md](dotfiles.md) has example files, editor completion and the
`cmux config` commands for scripts and agents.

## Moving between two cmux-next builds

Builds with different bundle ids (for example DEV and nightly-next, or a tagged dev build) keep
separate state. To move live terminals from one to the other, an agent runs this on the
destination's socket: `session.transfer.peers`, then `session.transfer.pull {source}`. The
playbook in [classic-to-next.md](classic-to-next.md) has examples. Terminals are recreated at
the destination as a new shell in the same folder, and the source terminal (its program and
scrollback) ends. A cmux-next source reports each terminal's `idle` (true when only its shell
runs) and `foreground_program`; both are null when it can't tell, and older builds and classic
leave them out. Move Sessions from Another cmux Build… in the command palette starts terminals
unchecked, offers only idle ones, and asks again, with no Return default, before it ends any.
A cmux-next agent chat moves into the destination's acpmux with its history,
queued prompts and unsent draft (`acpmux transfer`), then opens there; a chat in the middle of a
reply moves only with `{interrupt: true}`. Builds that share one acpmux (Release and NIGHTLY)
move only the tab. Classic agent chats resume by session id.

## Hot reload for the web UI

A Debug or NIGHTLY app picks up web UI edits from your own checkout live, with no build or
relaunch: `scripts/cmux-next/web-overlay.sh server --local`. A NIGHTLY can also follow each merge's
web UI (Settings > Updates > Web UI Updates > Every Merge). Details and troubleshooting are in
[hot-reload.md](hot-reload.md).
