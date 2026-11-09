# Uninstall cmux-next

Use this to remove a cmux-next build from a Mac completely, or to reinstall one from a clean
state. Deleting the app alone leaves its session daemons running, a login job, CLI links, data
in your home folder and Keychain items. The steps below remove each of those for one build, in
an order that never deletes something a running process still uses.

cmux classic shares some folders and, for NIGHTLY, its bundle id with cmux-next. Each step says
what is shared, so you can keep classic. Read [Keep classic](#keep-classic) first if you use it.

## 1. Pick the build

Every build keeps its own state, keyed by its bundle id. Set the three variables for the build
you're removing; every command below uses them.

| Build | App | `BUNDLE` | `TAG` |
|---|---|---|---|
| cmux NEXT DEV | `~/Applications/cmux NEXT DEV.app` | `com.cmuxterm.app.debug.next` | `next` |
| NIGHTLY (nightly-next) | `/Applications/cmux NIGHTLY.app` | `com.cmuxterm.app.nightly` | `nightly` |
| cmux NEXT (the older nightly-next identity) | `/Applications/cmux NEXT.app` | `com.cmuxterm.app.nightly.cmux-next` | `cmux-next` |
| A tagged dev build | `cmux DEV <tag>.app` | `com.cmuxterm.app.debug.<tag>` | `<tag>` (see below) |
| cmux classic (not cmux-next) | `/Applications/cmux.app` | `com.cmuxterm.app` | — |
| cmux classic NIGHTLY (not cmux-next) | `/Applications/cmux NIGHTLY.app` | `com.cmuxterm.app.nightly` | — |

NIGHTLY and classic NIGHTLY are the same app slot: nightly-next replaced classic NIGHTLY in place,
with the same name and bundle id. Removing NIGHTLY removes both.

```sh
BUNDLE=com.cmuxterm.app.debug.next
TAG=next
SESSION="cmux-app-$TAG"
APP="$HOME/Applications/cmux NEXT DEV.app"
# Not sure where it is? List every copy of this bundle id:
mdfind "kMDItemCFBundleIdentifier == '$BUNDLE'"
```

NIGHTLY keeps the shared roots older builds used; every other build has its own folders under
them. Set these too:

```sh
SUPPORT="$HOME/Library/Application Support/cmux"
NEXT_SUPPORT="$HOME/Library/Application Support/cmux-next"
if [ "$BUNDLE" = com.cmuxterm.app.nightly ]; then
  ACPMUX_DIR="$HOME/.acpmux"; CHIEF_DIR="$HOME/.cmux/chief/default"; BUILD_DIR=
else
  ACPMUX_DIR="$HOME/.acpmux/builds/$BUNDLE"; CHIEF_DIR="$HOME/.cmux/chief/$BUNDLE"; BUILD_DIR="$SUPPORT/builds/$BUNDLE"
fi
```

A tagged dev build whose bundle id holds characters outside `A-Za-z0-9._-` uses
`<bundle>--<hash>` instead of the bundle id in these folder names; `ls ~/.acpmux/builds` shows it.
A Chief signed in to another account has its own home beside `$CHIEF_DIR`: `$CHIEF_DIR@<account>`
(for NIGHTLY, `~/.cmux/chief/<account>`). `ls ~/.cmux/chief` shows them; treat each like
`$CHIEF_DIR` below.

A dev build tagged `nightly`, `rc`, `staging` or `cmux-next`, and the untagged
`com.cmuxterm.app.debug`, don't use their tag: their session is `cmux-app--<hash>` and their daemon
state is in `$BUILD_DIR/tui`, not `tags/<tag>`. Never set `TAG=nightly` for one of those, or the
steps below stop and delete NIGHTLY's. For them, leave `TAG` empty and set `SESSION` in step 4.

## 2. Before you quit: CLI and server

While the app runs, open the command palette (⇧⌘P) and run **Uninstall cmux CLI from PATH**
(or `cmux settings uninstall-cli-from-path`). It removes `/usr/local/bin/cmux` and
`/usr/local/bin/cmux-next` when they point into this app, asking for your password if it must.
Step 6 does the same by hand.

If you turned on serving this Mac (a Debug setting), run **Stop Serving** from the palette too. It
unregisters the app's login agent (`<bundle>.server`) and its privileged helper
(`<bundle>.server-helper`) and restores the power settings the helper changed.

## 3. Quit the app

Quit with ⌘Q. Quitting doesn't end your terminals or agents: they keep running in the session
daemon and in acpmux so the next launch can reattach. The next two steps end them.

## 4. Stop the session daemon and its terminals

Use the CLI inside the app, before you delete it. This ends every terminal of this build and the
programs running in them:

```sh
"$APP/Contents/Resources/bin/cmux" daemon stop --session "$SESSION" --end-terminals
```

Stopping a daemon that isn't running succeeds. Each session's socket is named after it, so
`ls "${TMPDIR%/}/cmux-tui-$(id -u)"` lists the running sessions (`cmux-app-<tag>.sock`, or
`cmux-app--<hash>.sock` for the builds in step 1's note); set `SESSION` to that name without
`.sock`.

Quitting also leaves the Chief running (its brain, `optchat-chief`, holds a lock in its home so
only one writer uses it). Stop it before you delete that home in step 7:

```sh
"$APP/Contents/Resources/bin/cmux" chief shutdown --chief-home "$CHIEF_DIR"
```

Then stop this build's acpmux and the agents it hosts:

```sh
ACPMUX_HOME="$ACPMUX_DIR" "$APP/Contents/Resources/bin/acpmux" daemon shutdown --end-agents
```

For NIGHTLY, `$ACPMUX_DIR` is `~/.acpmux`, the same home the standalone `acpmux` CLI uses, so
`--end-agents` ends every agent in it, including ones you started outside cmux. List them first
with `ACPMUX_HOME="$ACPMUX_DIR" "$APP/Contents/Resources/bin/acpmux" ls`. If any aren't yours to
end, drop `--end-agents` (the agents keep running) and keep `~/.acpmux` in step 7.

Check for anything still running. The session daemon (`cmux-tui`), its terminal hosts
(`__terminal-host`), holders (`cmux-holder`) and acpmux run from copies under
`~/Library/Application Support/cmux-tui/host-exe/`, so the bundle path doesn't always show:

```sh
ps -axo pid,ppid,command | grep -E '[c]mux-tui|[c]mux-holder|[a]cpmux|[o]ptchat-chief|[h]ost-exe'
```

Every cmux-next build's processes match. Stop only the ones you recognize as this build's (the
`--session cmux-app-<tag>` or socket in the command line, or a path under `$ACPMUX_DIR`), one pid
at a time, and wait for it to exit before you go on. A process can still be writing its files
for a moment after it gets the signal:

```sh
kill <pid>
ps -p <pid>        # until it prints only the header; after 10 seconds: kill -9 <pid>
```

Run the `ps -axo` check again before step 7. Delete nothing while this build's processes run.

Don't use `pkill` or `killall` here: they'd also end the daemons of every other build, and classic.

## 5. Remove login jobs

acpmux runs its daemon as a launchd job in your login session, labeled
`com.cmux.acpmux.daemon.<hash>`, where the hash comes from its home folder. List them with the
home each one belongs to:

```sh
for label in $(launchctl print "gui/$(id -u)" | grep -o 'com\.cmux\.acpmux\.daemon\.[0-9a-f]*' | sort -u); do
  echo "$label  $(launchctl print "gui/$(id -u)/$label" | grep -m1 'path = ')"
done
```

Boot out the one whose `path` is `$ACPMUX_DIR/daemon-login-session.plist`:

```sh
launchctl bootout "gui/$(id -u)/com.cmux.acpmux.daemon.<hash>"
```

Some CLI commands install launch agents of their own in `~/Library/LaunchAgents`. Look for them:

```sh
ls ~/Library/LaunchAgents | grep -E 'cmux|acpmux'
```

| Plist | Written by | Remove with |
|---|---|---|
| `com.acpmux.daemon.plist` | `acpmux daemon service install` | `acpmux daemon service uninstall` |
| `com.cmuxterm.link.plist` | `cmux link install-agent` | its running agent removes it once it sees the app is gone; if it's still listed, by hand, below |
| `com.cmuxterm.host-remote.plist` | `cmux host enable` | the same |
| `com.cmuxterm.automations.plist` | `cmux` automations | by hand, below |
| `com.cmux.server.plist` | `cmux server` with no app | by hand, below |

These are shared by every build; remove one only if you're done with what it runs. By hand:

```sh
launchctl bootout "gui/$(id -u)/<label>"
rm ~/Library/LaunchAgents/<label>.plist
```

Finally, open System Settings > General > Login Items & Extensions and remove any cmux item still
listed (the app's server agent if step 2 couldn't run).

## 6. Remove CLI links

Skip this if step 2 removed them. Remove only links that point into this app, so classic's
`cmux` link (into `cmux.app`) stays:

```sh
for link in /usr/local/bin/cmux /usr/local/bin/cmux-next $(which -a cmux cmux-next 2>/dev/null); do
  [ -L "$link" ] || continue
  case "$(readlink "$link")" in
    "$APP"/*) echo "removing $link"; rm "$link" 2>/dev/null || sudo rm "$link" ;;
    *) echo "keeping $link -> $(readlink "$link")" ;;
  esac
done
```

`which -a` also finds a link elsewhere on your PATH, such as `/opt/homebrew/bin/cmux`. Then delete
the app:

```sh
rm -rf "$APP"
```

## 7. Delete data

**Loses your data** marks folders you can't get back. Copy anything you want to keep first.

This build's own folders:

| Path | What it holds |
|---|---|
| `$ACPMUX_DIR` | **Loses your data.** Agent chats: every session's history, queued prompts and drafts, plus acpmux's config and trust. For NIGHTLY this is all of `~/.acpmux`, which also holds every other build's home under `builds/` and the standalone `acpmux` CLI's sessions |
| `$CHIEF_DIR` | **Loses your data.** Chief memory. NIGHTLY's is `~/.cmux/chief/default` |
| `$BUILD_DIR` | **Loses your data.** This build's app state (empty for NIGHTLY, whose state sits in `$SUPPORT` itself) |
| `$NEXT_SUPPORT/tags/$TAG` | **Loses your data.** The session daemon's saved workspaces, layout and scrollback. Builds before 2026-11 kept it in `$SUPPORT/tags/$TAG`, which is now a link here |
| `$NEXT_SUPPORT/managed-status.$BUNDLE.json` | Managed settings status |
| `$NEXT_SUPPORT/$TAG/debug-tunables.json` | Debug Settings overrides (DEV, NIGHTLY, cmux NEXT and tagged builds; other builds keep it in `$BUILD_DIR`) |
| `~/Library/Application Support/cmux-next/$BUNDLE` | **Loses your data.** SSH machine links (`ssh-next`), Cloud tunnel state and this Mac's Cloud device id (`cloud-next`), kept previous versions for rollback (`versions`) and the copy of classic's files read on migration (`classic-migration`) |
| `~/Library/Application Support/$BUNDLE` | Browser profiles (`BrowserProfiles`), backdrop images, table widths, and the `instance.lock` and `instance.owner` that keep one copy running |
| `~/Library/WebKit/$BUNDLE` | **Loses your data.** Browser tabs' cookies, logins and site data. Each cmux browser profile has its own WebKit store, named by the profile's id (listed in `~/Library/Application Support/$BUNDLE/BrowserProfiles/profiles.json`), under `WebsiteDataStore/` here |
| `~/Library/Caches/$BUNDLE` | Caches (update downloads, release notes) |
| `~/Library/HTTPStorages/$BUNDLE` | macOS's network cache for the app |
| `~/Library/Saved Application State/$BUNDLE.savedState` | macOS's window state |
| `~/Library/Logs/$BUNDLE` | Hang reports (not written by Release) |
| `~/Library/Logs/cmux-next/$BUNDLE-updater.log` | The updater's log |

```sh
rm -rf "$ACPMUX_DIR" "$CHIEF_DIR" ${BUILD_DIR:+"$BUILD_DIR"} ${TAG:+"$SUPPORT/tags/$TAG"} "$SUPPORT/$BUNDLE" \
  "$NEXT_SUPPORT/managed-status.$BUNDLE.json" ${TAG:+"$NEXT_SUPPORT/$TAG/debug-tunables.json"} \
  "$HOME/Library/Application Support/cmux-next/$BUNDLE" "$HOME/Library/Application Support/$BUNDLE" \
  "$HOME/Library/WebKit/$BUNDLE" "$HOME/Library/Caches/$BUNDLE" "$HOME/Library/HTTPStorages/$BUNDLE" \
  "$HOME/Library/Saved Application State/$BUNDLE.savedState" "$HOME/Library/Logs/$BUNDLE" \
  "$HOME/Library/Logs/cmux-next/$BUNDLE-updater.log"
```

For NIGHTLY, leave `$ACPMUX_DIR` out of that line unless you're removing every build.

Shared by every cmux-next build. Delete these only when you remove the last one:

| Path | What it holds |
|---|---|
| `~/.cmux/worktrees.noindex` and its `~/.cmux/worktrees` link | **Loses your data.** Git worktrees agents made, which can hold uncommitted or unpushed work. Check each with `git -C <worktree> status` first |
| `~/.cmux/accounts` | **Loses your data.** Per-account agent homes |
| `~/.cmux/chief`, `~/.cmux/host`, `~/.cmux/bin` | The rest of Chief, the remote host's pid and log, the CLI's `cmux-tui` copy |
| `~/.config/cmux/cmux-next.json`, `~/.config/cmux/keybindings.json` | **Loses your data.** Settings and key bindings ([dotfiles.md](dotfiles.md)) |
| `~/.config/cmux/` (other files: `machine-secrets.env`, `cloud-secrets.json`, `git-hosts/`, `themes/`, `skills/`, `server.json`, `web-dev.json`, `host-budget.json`) | **Loses your data.** Secrets, Git host tokens, themes and skills. `cmux.json` here is classic's |
| `~/Library/Application Support/cmux-tui` | The default session state root (`sessions`) and the copied daemon binaries (`host-exe`) |
| `$SUPPORT/Chat Uploads` | **Loses your data.** Files attached to chats |
| `$SUPPORT/agent-home` | **Loses your data.** The folder chats with no project run in, and what agents wrote there |
| `$NEXT_SUPPORT/recovery` | **Loses your data.** Unsaved file drafts kept for recovery after a crash |
| `$NEXT_SUPPORT/voice-room` | Voice Room keyframes (Labs) |
| `$NEXT_SUPPORT/login-environment.json` | Your login shell's environment, captured for agents |
| `$NEXT_SUPPORT/server-fix-ledger` | Which power settings the server helper changed (step 2) |
| `$SUPPORT/last-app-cli` | Which app's CLI ran last |
| `~/Library/Logs/cmux-next` | Crash reports and updater logs of every build |
| `"$(dirname "$APP")/.$(basename "$APP").installed"` | What the DEV update script installed last, beside the app (DEV only) |

Sockets and locks are rebuilt on launch. These folders hold every running build's sockets, so
delete them only when no cmux build runs at all, classic included:

```sh
rm -rf "${TMPDIR%/}/cmux-tui-$(id -u)" /tmp/cmux-tui-$(id -u) /tmp/cmux-th-$(id -u) \
  /tmp/cmux-hd-$(id -u) /tmp/cmux-apps-$(id -u)
ls ~/.local/state/cmux/*.sock /tmp/cmux-*.sock 2>/dev/null   # control sockets; remove this build's
```

A build's control socket is `~/.local/state/cmux/cmux-<name>.sock` or `/tmp/cmux-<name>.sock`:
`cmux-debug-next` for DEV, `cmux-nightly` for NIGHTLY, `cmux-nightly-cmux-next` for cmux NEXT,
`cmux-debug-<tag>` for a tagged build.

If you allowed the server helper (step 2), it left its record in a root folder:
`sudo rm "/Library/Application Support/cmux/server-helper/$BUNDLE.server-helper.json"`.

## 8. Preferences and Keychain

Delete preferences with `defaults`, not by deleting the plist. `cfprefsd` caches preferences, and
a deleted file can come back from its cache:

```sh
defaults delete "$BUNDLE"
```

Keychain items in the login keychain carry the bundle id in their service name. Each
`security delete-generic-password` call removes one item, so this loops until none are left:

```sh
for suffix in ai-provider-keys account-label-salt browser-http-auth cookie-backup-key device-hub \
    mac-screen iphone-host.identity iphone-host.pairing-seal; do
  while security delete-generic-password -s "$BUNDLE.$suffix" >/dev/null 2>&1; do :; done
done
while security delete-generic-password -s "com.cmuxterm.next.free-tier.app-attest.$BUNDLE" >/dev/null 2>&1; do :; done
```

`ai-provider-keys` holds the API keys you added. The Cloud install key's service name ends in
the API host (`$BUNDLE.install-key.<host>`); search Keychain Access for the bundle id to find it.
A few items (`mac-approver`, `act-as-me`) live in the data-protection keychain, which `security`
can't reach; they stay behind, and a reinstall of the same build reads them again.

Shared by every cmux-next build: `cmux-cloud-secret`, `cmux-vault` (acpmux's vault),
`com.cmuxterm.app.next.carrier-noise-key` and `cmux-next VNC`. Remove those only with the last
build, the same way (`security delete-generic-password -s <service>`, repeated).

For NIGHTLY, `defaults delete com.cmuxterm.app.nightly` also deletes classic NIGHTLY's preferences,
because they're the same file.

## Keep classic

cmux classic is `cmux.app` (`com.cmuxterm.app`), plus classic NIGHTLY on
`com.cmuxterm.app.nightly`. To remove a cmux-next build and keep classic, never delete:

- `~/Library/Application Support/cmux/` as a whole. Classic keeps `session-<bundle>.json`,
  `session-history/` and `agent-journal-<bundle>.sqlite3` there, and `cmux-cua/` is shared
  with classic's Computer Use. Delete only the cmux-next paths from step 7.
- `~/.cmuxterm/`: classic's agent hook stores.
- `~/.config/cmux/cmux.json`: classic's settings.
- `~/Library/Logs/cmux-update.log` and `cmux-focus.log`: classic's logs.
- Anything for `com.cmuxterm.app`, and, while you keep classic NIGHTLY, anything for
  `com.cmuxterm.app.nightly` (its preferences, caches and `$SUPPORT` itself).

cmux-next only reads classic's files. Its migration copy is in
`~/Library/Application Support/cmux-next/<bundle>/classic-migration/backups/`.

## Reinstall clean

To start a build over, do steps 1-7 for it and step 8's `defaults delete`, then install it again
([README.md](README.md)). The first launch after that can import classic's last saved session
again, as on a new Mac ([classic-to-next.md](classic-to-next.md)); set
`CMUX_NEXT_CLASSIC_MIGRATION=0` to skip it. To keep your chats' history across a reinstall,
leave `$ACPMUX_DIR` in place.

Moving to a different build instead keeps both data sets: move live terminals and chats with
**Move Sessions from Another cmux Build…** first ([README.md](README.md#moving-between-two-cmux-next-builds)),
then remove the old build here.
