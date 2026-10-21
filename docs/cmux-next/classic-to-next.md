# Move from cmux classic to cmux-next

Use this when someone switches from cmux classic to cmux-next and wants their
work to come along: recent workspaces (folder, title, terminals and their launch
or SSH commands) and Claude Code or Codex chats, resumed by session id. An agent
can follow it end to end. Nothing here modifies classic's files.

Usually nothing is needed: the first launch of cmux-next after the update
brings classic's last saved session over once, by itself. Every window comes
back with its workspaces in sidebar order, their groups (name, color, icon,
collapsed, pinned), colors and pins, with the same panes, splits, tabs and tab
names. A toast says what came over and what stayed. Later launches make
nothing again. If you go back to classic and then update again, only the
workspaces classic made in between come over, into the same groups. Classic's
files are only read; a copy of what was read is kept in
`~/Library/Application Support/cmux-next/<bundle id>/classic-migration/backups/`.
Set `CMUX_NEXT_CLASSIC_MIGRATION=0` to turn it off. When cmux-next was already
in use before this build, the first launch only records classic's workspaces
and opens none.

To bring workspaces over by hand, run **Import Workspaces from Classic cmux**
in cmux-next's command palette, or `cmux workspace import-classic`. It opens
every workspace from classic's last saved session that is not open here (one
you closed here comes back), never a duplicate, and shows a toast when it
finishes.

- Terminals open in their folders. A command that was running doesn't start
  again. A terminal's saved scrollback prints once above its first prompt, as
  plain output with its colors; titles, links and other terminal codes in it
  are dropped. This needs cmux-next's shell integration (zsh, bash or fish).
- Browser tabs open on their pages, in the same pane and order. A tab keeps a
  name you gave it; otherwise it shows the page's title.
- A terminal that ran a Claude Code or Codex session opens as a chat that
  resumes that session (acpmux adopt), in the same pane and place, under the
  chat's own title. It stays a terminal in its folder when a tab already
  resumes that session, or when acpmux can't resume it as a chat.
- SSH workspaces open on their host, as if you had run SSH… with
  `user@host:port`. Classic's identity file and SSH options don't come over, so
  the host must work from `~/.ssh/config` and your SSH agent, and it needs
  cmux-tui. A host that doesn't connect within 20 seconds stays in classic, and
  the toast says so; the import doesn't try it again for its other workspaces,
  and a machine it added for that host is removed again. An agent session in an
  SSH workspace opens as a terminal, because adopted chats run on this Mac.
  An SSH terminal opens without its old scrollback, and the toast says so.
- Cloud VM workspaces stay in classic, and the toast says so: cmux-next
  can't attach a classic VM yet.
- Markdown viewers and file previews stay in classic, and the toast says so.
  A pane that held only those closes up, and its neighbour takes its space.

To choose what comes over, or to bring launch commands too, use
[`scripts/cmux-next/classic-to-next.py`](../../scripts/cmux-next/classic-to-next.py)
and cmux-next's control socket, as below.

## 1. Start cmux-next

cmux-next must be running. The script finds its control socket on its own
(the first socket whose `system.identify` answers like cmux-next). Pass
`--socket PATH` when more than one cmux-next build is running:

| Build | Socket |
| --- | --- |
| Tagged dev build | `~/.local/state/cmux/cmux-debug-<tag>.sock` (symlink at `/tmp/cmux-debug-<tag>.sock`) |
| Nightly, RC, staging | `~/.local/state/cmux/cmux-<channel>[-<tag>].sock` (symlink at `/tmp/cmux-<channel>[-<tag>].sock`) |
| Release | `~/.local/state/cmux/cmux.sock` |

## 2. List what classic has

```sh
python3 scripts/cmux-next/classic-to-next.py
```

This reads, read only:

- `~/Library/Application Support/cmux/session-<bundle>.json` and its `-previous` copy (the open windows);
- `~/Library/Application Support/cmux/session-history/` (earlier snapshots);
- `~/Library/Application Support/cmux/agent-journal-<bundle>.sqlite3` (every agent session classic saw, opened with `mode=ro&immutable=1`);
- `~/.cmuxterm/<agent>-hook-sessions.json` (the agent hook stores);
- for a past chat whose folder classic didn't record, the agent's own transcript
  (`~/.claude/projects/*/<id>.jsonl`, `~/.codex/sessions/**/rollout-*<id>.jsonl`).

Output, newest first:

```text
  a1  claude 7e0b2a44-...  2026-10-10 18:02  /Users/me/src/old-proj
  a2  claude 1f6c3c51-...  2026-10-10 19:40  /Users/me/src/api  claude chat
  w1  api server  2026-10-10 19:40  /Users/me/src/api  1 terminal(s)  agents a2
        - dev  /Users/me/src/api  npm run dev
```

`a<N>` rows are agent chats and `w<N>` rows are workspaces. A workspace lists
the chats that were open in it. Use `--days N` to widen the window (the default
is 30; `0` shows everything) and `--json` for machine-readable output.

## 3. Choose with the person

Suggest the recent and active work first: the workspaces from the live snapshot
and the chats seen in the last few days. Ask before moving anything, and
confirm the selection by row id (`w1,a2`). Leave a chat with
`(folder unknown)` out unless the person names its folder.

## 4. Reopen the selection in cmux-next

See what would run:

```sh
python3 scripts/cmux-next/classic-to-next.py --commands --select w1,a2
```

Then apply it:

```sh
python3 scripts/cmux-next/classic-to-next.py --apply --select w1,a2
```

- An agent chat opens as a cmux-next agent chat in its folder, resumed by its
  Claude Code or Codex session id.
- A workspace opens as a new cmux-next workspace in its folder, with a terminal
  per classic terminal, each in its own folder with its launch or SSH command.
  It keeps classic's layout: each classic pane becomes a cmux-next pane with
  the same tabs in the same order, and each split keeps its direction and
  divider position. Selecting a workspace also brings the chats that were open
  in it.
- Each row prints `ok` or `FAIL` with the reason. Rows open once even when
  selected twice.

`--apply` sends `session.transfer.open` over the socket. When that fails, for
example on a cmux-next build older than this script, `--commands` also prints
a `cmux action run newTab` line per row that works with any build's CLI. Its
agent rows resume the chat in a terminal (`claude --resume <id>`,
`codex resume <id>`) instead of an agent chat.

What the layout leaves out:

- Each pane opens on its last tab, not the tab classic had selected.
- A chat opens as its own workspace (above), and browser tabs don't come over.
  A pane that held only those closes up, and its neighbour takes its space.
- The `cmux action run newTab` fallback opens one workspace per terminal, with
  no splits.
- A canvas workspace (classic's freeform layout) comes over as tabs in one pane.
- A terminal the saved layout doesn't place (a damaged session file) joins the
  first pane as a tab.

## 5. Move live classic sessions (optional)

When classic is still running, cmux-next can take its open terminals and chats
directly. A move opens a new shell (or the agent chat, resumed) in cmux-next in
the same folder, then classic closes its tab, which **ends the process running
there**: unsaved editor buffers, running jobs and scrollback are lost. Agree on
each item with the person before moving it; when in doubt, use steps 2-4, which
leave classic untouched.

Talk to the cmux-next socket with one JSON line per request:

```sh
# sibling builds, each with its socket and movable sessions
printf '%s\n' '{"id":1,"method":"session.transfer.peers","params":{}}' | nc -U <cmux-next socket>
# move from one build: "source" is a socket from the list, "ids" its sessions (all when omitted)
printf '%s\n' '{"id":1,"method":"session.transfer.pull","params":{"source":"/tmp/cmux.sock","ids":["<surface id>"]}}' | nc -U <cmux-next socket>
```

On a tagged dev build, `cmux --app-socket <socket> app call session.transfer.pull '{...}'`
does the same. The reply lists `moved` and `failed` items. An agent chat moves
only when cmux-next opened it; otherwise it's reported as failed and classic
keeps it. A terminal's launch command isn't run again, except an SSH command.

Classic's default socket mode (`cmuxOnly`) admits only processes started in
classic's own terminals, so the pull fails with `access_denied`. Ask the person
to set classic's socket control mode to Automation first (Settings, or
`automation.socketControlMode` in `~/.config/cmux/cmux.json`), or use steps 2-4,
which need no classic socket.

## 6. Check the result

In cmux-next, the new workspaces carry the classic titles and folders. Over
the socket, `snapshot.get` lists them under `topology.workspaces`, with each
tab's `cwd` and, for a chat, `agent` (`claude` or `codex`). Classic's files are
unchanged; the script never writes them.

The live check `scripts/cmux-next/classic-to-next-live.py --app <cmux-next.app>
[--classic-app <classic.app>]` seeds classic data in a scratch folder and runs
this whole flow on a fleet mini.
