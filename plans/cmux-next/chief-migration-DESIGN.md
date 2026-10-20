# Moving a Chief between hosts

Status: design + phase 1 (checkpoint format, home-to-home move over SSH), 2026-10-20.
Owner lane: a283 ("Chief moves between hosts"). Related: optchat.md section 3 (placements),
cloud-chief-vm.md section 5 (placement handoff), remote-hosts.md (tailnet hosts),
cloud-subagents-DESIGN.md (acpmux peers on a VM), the Hosted Chief copy
(`HostedChiefCopy.swift`, commit 34b8d065bd4), a185 (Chief turn resume), a262 (one Chief list).

## 0. Goal

Lawrence (2026-10-20): "start Chief on this computer, move it to the Mac mini, then to a Linux
GCP VM, then completely to cmux cloud Durable Objects", seamlessly.

One action, **Move Chief to...**, from Home's Chief settings, Cmd+Shift+P, `cmux chief move
--to <host>` and MCP. It checkpoints the Chief, transfers it, verifies it on the target, then
makes the target the one place that answers. No message is lost; the old copy stays as the
rollback until the user drops it.

## 1. What a Chief is on disk

A Chief home (`~/.cmux/chief/<name>`, cmux-tui `cli/chief/home.rs`) is self-contained:

| Part | Path | Kind | Moves |
| --- | --- | --- | --- |
| Memory: log, tree, host state (subagent ids, cursors, `control cap` and `control cloud PEER` settings as `host/*` rows) | `optchat/memory.sqlite3` | SQLite (WAL) | yes, as a consistent copy |
| Memory text export (git, backup remote) | `optchat/chat/` | files + `.git` | yes |
| Person profile, instructions, avatar, profile, engine, settings | `optchat/person.md`, `AGENTS.md`, `avatar.png`, `profile.json`, `engine.json`, `settings.json`, `chief-settings.json`, `backup-allow.txt` | files | yes |
| Conversation owner (the Home chat, other Chiefs, attachments) | `tui/<session dir>/conversations.sqlite3`, `chiefs.sqlite3`, `attachments/`, `apps.json`, `identity` | SQLite + files | yes; the session dir is renamed (section 3) |
| Subagent transcripts and registry | `acpmux/sessions/`, `acpmux/chat-index/`, `acpmux/presets/`, `acpmux/config.json`, `acpmux/trust.json`, `acpmux/attachments/`, `acpmux/mailbox/` | files | yes (`--without-transcripts` skips `sessions/`) |
| Agent token, adopted list, migration record | `agent-token`, `adopted.json`, `migration.json` | files | yes |
| Sockets, locks, pids, logs, traces, caches, launchers, per-session Claude/Codex config, login env | `*.sock`, `*.lock`, `*.pid`, `*.log`, `optchat/traces`, `optchat/claude`, `compactor-*`, `turn-codex`, `session`, `bin`, `codex`, `acpmux/run`, `acpmux/live-models`, `acpmux/login-env.json`, `acpmux/router`, `acpmux/hosts` | machine-local | never: the target rebuilds them; login env and router stay per machine |

The machine-local list is a denylist in code (`migrate::LOCAL_NAMES`, `LOCAL_SUFFIXES`,
`LOCAL_DIRS`): a new file moves unless someone marks it machine-local on purpose, because a file
left behind can lose messages and a file carried along only costs bytes. `optchat/subagent`
(the subagent working directory the host writes) is machine-local too.

## 2. Checkpoint format `cmux-chief-checkpoint/1`

A directory (sent as a tar stream):

```
manifest.json
files/<relative path as in the home>
```

`manifest.json`:

```json
{
  "format": "cmux-chief-checkpoint/1",
  "chief": {"home_name": "default", "session_dir": "cmux-chief-2e448bc2-5091cba499ba5899"},
  "source": {"host": "lawbook", "os": "macos", "arch": "aarch64", "root": "/Users/…/.cmux/chief/default"},
  "created_at": "2026-10-20T21:00:00.000Z",
  "memory": {"messages": 5139, "nodes": 10100, "last_message_id": 5138},
  "conversations": {"messages": 4321},
  "files": [{"path": "optchat/memory.sqlite3", "size": 1234, "sha256": "…", "mode": 384}]
}
```

Rules:

1. SQLite files are copied with `VACUUM INTO` (one consistent file, no `-wal`/`-shm`), so a
   checkpoint can be taken while the host runs; the move itself takes it after the drain
   (section 4), so nothing changes after it.
2. Every file has its SHA-256 and mode; restore refuses a mismatch before it writes anything
   into the target home.
3. `memory` and `conversations` counts are read from the copies, and checked again on the target.
4. Paths are relative; nothing absolute from the source is restored.
5. The same checkpoint feeds every target kind (section 5).

## 3. Path-dependent names

Two names derive from the home's absolute path and change on a new machine:

- the daemon session name `cmux-chief-<FNV-1a 32 of the root>` and its state directory
  `tui/<session_storage_component(name)>` (`cmux-tui-core` workspace_registry.rs);
- the acpmux preset tag `home_id(root)` (optchat-chief paths.rs).

Restore renames `tui/<source dir>` to the directory the target root derives, and the host
rebuilds presets on start. `migrate::session_dir_for(root)` reimplements both hashes; a test
pins them to a real home (`/Users/lawrence/.cmux/chief/default` ->
`cmux-chief-2e448bc2-5091cba499ba5899`).

## 4. The move (one history, one writer)

`optchat-chief move --to <target> [--home DIR]` on the source:

1. **Preflight**: the target is reachable, has `optchat-chief` that knows the format, has room
   (2x the checkpoint size), and its home is empty or absent. Nothing is stopped yet.
2. **Drain**: write `state/shutdown` (the app starts no brain), wait for the host lock to be
   free (the host finishes its turn: a185's turn resume makes this safe mid-turn later), refuse
   when subagents still run unless `--subagents finish|leave` (section 6).
3. **Checkpoint** into a temp directory; verify it locally.
4. **Transfer**: `tar` over `ssh` into `<target home>.incoming`.
5. **Restore** on the target: `optchat-chief move restore --from DIR --home HOME` checks every
   hash, writes into an empty home, renames the session dir, writes `state/moved-in.json`.
6. **Verify** on the target: `memory check` opens the memory as the host does; the message,
   node and conversation counts equal the manifest's.
7. **Commit**: the source gets `state/moved.json` `{to, at, checkpoint_sha}`; a host refuses to
   start on a home with that file (exit 3, "this Chief moved to X"). Then the target host
   starts (`--start`).
8. **Switch Home**: the app reads `moved.json` and shows the Chief at its new place (section 7).

A failure before step 7 leaves the source answering (remove `state/shutdown`); the target's
partial home stays as `.incoming` for inspection. **Rollback** (`move --rollback`) after step 7:
stop the target host, write `moved.json` on the target pointing back, delete `moved.json` and
`state/shutdown` on the source. The source copy is the pre-move state, so messages the target
answered after the move are lost by a plain rollback; `move --to <source>` instead brings them
back (a move in reverse). The source copy is kept until `move --forget-source`.

## 5. Targets

| Target | `--to` | Conversation lives | How |
| --- | --- | --- | --- |
| This Mac, another home (test, second account) | `local:/path` | target home | restore directly |
| Mac mini / any Mac over SSH | `ssh:<host>[:/path]` | target home's daemon | steps above; Home dials the host (section 7) |
| Linux VM (GCP) over SSH | `ssh:<host>[:/path]` | same | same; needs Linux `optchat-chief` + `cmux` there |
| Placed host answering the cloud conversation | `server:<chief id>` | ConversationDO | the cloud import op + memory text export (cloud-chief-vm.md 5) |
| cmux cloud (Durable Objects) | `cloud` | ConversationDO + ChiefBrainDO | HostedChiefCopy's path from the checkpoint |

### 5.1 Durable Objects storage mapping

| Checkpoint part | DO home |
| --- | --- |
| `memory.sqlite3` messages, nodes, state | the brain's MemoryDO SQLite (`messages`, `nodes`, `state` tables: same schema through optchat-core in WASM, optchat.md 4), loaded by the existing memory PUT of the text export |
| `chat/` text export | the PUT body; R2 copy as the backup |
| `conversations.sqlite3` main conversation | ConversationDO through `conversation.import` (fill + commit, idempotent by message key) |
| other conversations (DMs, groups) | one ConversationDO each, same import |
| `chiefs.sqlite3`, profile, avatar, person.md, engine | the chief record (`chief.update`: name, avatar, brain options) and the brain's settings |
| acpmux sessions and registry | not moved into a DO: subagents re-home to Freestyle acpmux peers (a242); finished transcripts go to R2 for `zoom("aN")` |
| agent token | not moved: the cloud mints its own chief token |

## 6. Subagents

- **finish** (default when any run): the move waits until every running subagent's turn ends
  (bounded by `--drain-timeout`, default 30 min), then moves; no subagent is cut.
- **leave**: running subagents keep running on the source's acpmux; the target Chief reaches
  them as acpmux peers (a242: `OPTCHAT_SUBAGENT_PEER`), and their reports reach the moved Chief.
  Phase 2.
- Finished subagents move as transcripts, so `zoom("aN")` keeps working.

## 7. Home after a move

- The source's `state/moved.json` names the target. The app's Chief list (a262: one list, a
  location line per Chief) shows the Chief once, with its new location ("Mac mini"), never twice.
- Mac mini and Linux VM targets are tailnet hosts (remote-hosts.md): Home opens the Chief
  session over `cmux host dial`. Phase 1 `host serve` splices the `main` session only; serving a
  Chief session needs a `session` field in the preface (phase 2 of this lane).
- Cloud targets: Home shows the cloud Chief as today (HomeChiefSource prefers the placed Chief).

## 8. Entry points (one shared path)

- CLI: `cmux chief move --to <target> [--subagents finish|leave] [--dry-run] [--rollback]`
  forwards to `optchat-chief move` (one implementation).
- MCP: `chief.move {to, dry_run}` (the same verb).
- Cmd+Shift+P "Move Chief to..." and Home's Chief settings row open one sheet that lists
  targets from `cmux host list`, paired servers and Cloud, shows the dry-run report, then runs
  the move with live steps. Phase 2 (Swift).

## 9. Safety

- The user's main Chief never moves without a checkpoint kept on the source and a tested
  rollback; the first moves run on throwaway homes.
- One writer: the drain plus `moved.json` make two hosts answering impossible on purpose; the
  host refuses to start on a moved home.
- The checkpoint holds everything the user pasted: the temp directory is 0700, the transfer is
  SSH only, and the `.incoming` copy is deleted after a verified restore.

## 10. Phases

1. (this change) `migrate` module: checkpoint format, restore, verify, moved marker and the
   host's refusal; `optchat-chief move` with `local:` and `ssh:` targets; `cmux chief move`
   forward; tests that fail before the code.
2. Home switch for tailnet hosts (`host serve` session field), the Swift sheet and palette
   action, MCP verb, `--subagents leave` through acpmux peers.
3. `server:` and `cloud` targets from the checkpoint (reuse HostedChiefCopy's ops), with the
   reverse (cloud to Mac) export.

## 11. Open

- GCP VM hop: needs a Linux `optchat-chief` and `cmux` on the VM; the fleet builds macOS only.
- Durable Objects hop: the brain memory PUT and `conversation.import` exist; a CLI path to them
  needs the user's cloud session token on the source machine (the app has it, the CLI does not).
