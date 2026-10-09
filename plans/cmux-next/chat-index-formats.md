# Chat index: store formats, versions and roots

Bead cx-s1cg. The sidebar "All chats" section lists every chat of every coding
agent harness on the computer, newest first. `cmux-tui/crates/cmux-chat-index`
reads the stores; acpmux (`crates/acpmux/src/chats`) discovers roots, watches
them and serves the list. This file records every on-disk format that shipped,
the evidence for it, and the test that covers it. A store can hold several
generations at once (most migrations copy and never delete), so each adapter
reads all of them side by side and removes duplicates by session id, newest
store first.

Contract for every adapter: read-only (SQLite through `sqlite::open_read_only`:
read-only flags, `query_only`, busy timeout, a 2 s progress deadline, no
ATTACH), titles and metadata only (one title line of at most 120 characters,
no other transcript text), bounded reads and walks, no panic on corrupt input
(`tests/corrupt.rs` writes 15 kinds of garbage at every path each layout
knows). Every fixture is synthetic, built from the documented schema.

Evidence key: "bundle" means a shipped npm or binary build was read because
the source is closed. Commit SHAs are of the named repo.

## Roots per platform

`src/roots/table.rs` is the table; `tests/platform_roots.rs` runs it for
macOS, Linux and Windows with an injected home and env on any host. Env
overrides come first. "home" is the user profile (`%USERPROFILE%` on
Windows). Windows `%APPDATA%` and `%LOCALAPPDATA%` fall back to
`home\AppData\Roaming` and `home\AppData\Local` when unset.

| Harness (id) | Env overrides | macOS | Linux | Windows |
|---|---|---|---|---|
| Claude Code (`claude-code`) | `CLAUDE_CONFIG_DIR`/projects, `XDG_CONFIG_HOME`/claude/projects | `~/.claude/projects`, `~/.config/claude/projects` | same as macOS | `home\.claude\projects` |
| Codex (`codex`) | `CODEX_HOME` | `~/.codex` | `~/.codex` | `home\.codex` |
| OpenCode (`opencode`) | `XDG_DATA_HOME`/opencode | `~/.local/share/opencode`, `~/Library/Application Support/opencode` (0.0.53-0.0.55) | `~/.local/share/opencode` | `home\.local\share\opencode`, `%LOCALAPPDATA%\opencode\Data` (0.0.53-0.0.55) |
| Pi (`pi`) | `PI_CODING_AGENT_SESSION_DIR`, `sessionDir` in `<agent dir>/settings.json`, `PI_CODING_AGENT_DIR`/sessions, `CODING_AGENT_DIR`/sessions | `~/.pi/agent/sessions`, `~/.coding-agent/sessions` | same | `home\.pi\agent\sessions`, `home\.coding-agent\sessions` |
| Gemini CLI (`gemini`) | `GEMINI_CLI_HOME`/.gemini | `~/.gemini`, `~/.cache/.gemini` (seatbelt sandbox) | `~/.gemini` | `home\.gemini` |
| Cursor agent (`cursor-agent`) | `CURSOR_DATA_DIR`/chats, `CURSOR_CONFIG_DIR`/chats, `XDG_CONFIG_HOME`/cursor/chats | `~/.cursor/chats` | same | `home\.cursor\chats` |
| Amp (`amp`) | `XDG_DATA_HOME`/amp/threads | `~/.local/share/amp/threads` | same | `home\.local\share\amp\threads` |
| Qwen Code (`qwen-code`) | `QWEN_RUNTIME_DIR`, `QWEN_HOME` | `~/.qwen` | same | `home\.qwen` |
| Copilot CLI (`copilot-cli`) | `COPILOT_HOME`, `XDG_STATE_HOME`/.copilot | `~/.copilot` | same | `home\.copilot` |
| Grok Build (`grok`) | `GROK_HOME`/sessions | `~/.grok/sessions` | same | `home\.grok\sessions` |
| grok-cli (`grok-cli`) | none | `~/.grok` (`grok.db`) | same | `home\.grok` |
| kimi-cli (`kimi-cli`) | `KIMI_SHARE_DIR` | `~/.kimi`, `<XDG data>/kimi` (v0.32-v0.33) | same | `home\.kimi`, `home\.local\share\kimi` |
| Kimi Code (`kimi-code`) | `KIMI_CODE_HOME` | `~/.kimi-code` | same | `home\.kimi-code` |
| goose (`goose`) | `GOOSE_PATH_ROOT`/data/sessions | `<XDG data>/goose/sessions` | same | `%APPDATA%\Block\goose\data\sessions` |
| Droid (`droid`) | `FACTORY_HOME_OVERRIDE`/.factory/sessions | `~/.factory/sessions` | same | `home\.factory\sessions` |
| Cline (`cline`) | `CLINE_DATA_DIR`, `CLINE_DIR`/data | `~/.cline/data` + globalStorage `saoudrizwan.claude-dev` | same | same |
| Roo Code (`roo-code`) | none | globalStorage `rooveterinaryinc.roo-cline` | same | same |
| Kilo Code extension (`kilo-code`) | none | globalStorage `kilocode.kilo-code`, `~/.kilocode/cli/global` | same | same |
| Kilo CLI (`kilo`) | `XDG_DATA_HOME`/kilo | `~/.local/share/kilo` | same | `home\.local\share\kilo` |
| Crush (`crush`) | `CRUSH_GLOBAL_DATA`, `XDG_DATA_HOME`/crush | one root per project `data_dir` in `~/.local/share/crush/projects.json` | same | also `%LOCALAPPDATA%\crush\projects.json` |
| Auggie (`auggie`) | none | `~/.augment/sessions` | same | `home\.augment\sessions` |
| Continue (`continue`) | `CONTINUE_GLOBAL_DIR`/sessions | `~/.continue/sessions` | same | `home\.continue\sessions` |
| OpenHands (`openhands`) | `OPENHANDS_CONVERSATIONS_DIR`, `OPENHANDS_PERSISTENCE_DIR`/conversations | `~/.openhands/conversations` | same | `home\.openhands\conversations` |

VS Code globalStorage is `<user data>/User/globalStorage/<extension id>` for
the editors Code, Code - Insiders, Cursor, Windsurf, VSCodium and Code - OSS.
`<user data>` is `~/Library/Application Support/<App>` (macOS),
`$XDG_CONFIG_HOME/<App>` (Linux) and `%APPDATA%\<App>` (Windows).

Every candidate goes through acpmux's `refuse` check before any read, so a
root inside a protected folder (Documents, Desktop, iCloud) is refused with a
reason. Crush project dirs are roots for this reason: they come from an index
file and can be anywhere.

## Format matrix

### Claude Code (closed source; evidence: npm bundles, claude-agent-sdk 0.3.287 `sdk.mjs`, ryoppippi/ccusage@0881239)

| Format | Versions | Layout | Covered by |
|---|---|---|---|
| Cache JSON | before 0.2.93 | writes were no-ops in public bundles (0.2.9, 0.2.50) | nothing to read |
| SQLite `__store.db` | 0.2.90-0.2.109 (2025-04/05) | `<home>/.claude/__store.db`: `base_messages`, `user_messages`, `conversation_summaries` (drizzle; timestamps in seconds) | `the_sqlite_store_of_claude_0_2_90_lists_its_sessions_beside_jsonl` |
| JSONL per session | 0.2.106+ | `<config>/projects/<enc cwd>/<uuid>.jsonl`; records `user`, `assistant`, `summary`, `custom-title` (2.0.64), `ai-title` and `last-prompt` (2.1.80), `relocated`, `continued-in`; NUL padding possible | `claude_code.rs`, `nul_padded_lines_relocation_and_the_title_sidecar_are_read`, `a_session_continued_in_another_is_left_out` |
| Subagents | inline `isSidechain` (to 2.0.27), flat `agent-*.jsonl` (2.0.28-2.1.1), `<uuid>/subagents/` (2.1.2+) | skipped | `sidechain_files_and_subagents_are_not_chats` |
| Title sidecar | 2.1.x | `<enc>/<uuid>/custom-title.json` `{customTitle}` | `nul_padded_lines_...` |
| XDG config dir | 1.0.28-1.0.31 (changelog 1.0.28) | `$XDG_CONFIG_HOME/claude` when set; `~/.config/claude` scanned by default as ccusage does | `per_platform_defaults_match_each_harness` |

Title order follows the SDK: custom title, sidecar, AI title, last prompt,
first typed prompt. `history.jsonl` and `sessions/<pid>.json` are not chats.

### Codex (openai/codex)

| Format | Versions / evidence | Layout | Covered by |
|---|---|---|---|
| A: TypeScript CLI | 59a180dd (2025-04-16) to 408c7ca1 (#2048, 2025-08) | `~/.codex/sessions/rollout-YYYY-MM-DD-<uuid>.json` `{session:{timestamp,id,instructions}, items}`; rewritten each turn; no resume | `the_typescript_cli_json_rollout_is_read_only` |
| B: Rust, no wrapper | 42617f87 (rust-v0.0.2505101753); dated dirs fcbcc40f (rust-v0.8.0); `git` meta 2437a8d1 | line 1 `{id,timestamp,instructions}`, bare response items; cwd only in `<environment_context>` | `unwrapped_rust_rollouts_take_id_folder_and_prompts_from_bare_items` |
| C: RolloutLine wrapper | 43809a45 (#3380, rust-v0.32.0) | `sessions/YYYY/MM/DD/rollout-<ts>-<id>[_<rollout>].jsonl[.zst]`, `session_meta` first; subagent `source.subagent` / `thread_source` skipped; IDE preamble `## My request for Codex:` stripped | `wrapped_rollouts_skip_subagent_threads_and_strip_the_ide_preamble`, `codex.rs` |
| Archive | ace14e8d (rust-v0.32.0) | flat `archived_sessions/` | `codex.rs` |
| Names | 1ef5455e (rust-v0.93.0) | `session_index.jsonl` | `the_session_index_names_threads_when_the_db_has_no_name_column` |
| State DB | 3878c3dc (rust-v0.93.0), `state_N.sqlite` 583e5d4f, frozen `state_5` 95ca2763 | `threads` table, columns probed (`*_ms` from migration 0025) | `the_newest_state_db_gives_threads_with_names_titles_and_filters` |
| `has_user_event` unused | Codex 0.159/0.160 (seen 0.159.3 on cmux-lawrence-2: 112 threads, all 0) | a thread is listed when `has_user_event = 1` or any of `first_user_message`, `title`, `preview`, `name` is set; `thread_source = 'subagent'` is skipped | `codex_0_160_threads_with_has_user_event_0_are_listed_when_they_have_a_prompt` |
| zstd rollouts | a8a60712 (rust-v0.137.0) | listed without a count (no zstd reader) | `without_a_db_rollout_files_are_read_and_zst_has_no_count` |

### OpenCode (anomalyco/opencode, formerly sst/opencode)

| Format | Versions / evidence | Layout | Covered by |
|---|---|---|---|
| Go program | v0.0.1-v0.0.52 | different product, not indexed | none |
| J0 nested | v0.0.53-v0.0.55 (env-paths data dir) | `<data>/<absolute repo path>/storage/session/info/<id>.json` | `per_project_json_storage_before_0_6_with_inline_and_split_parts` |
| J0 per project | v0.1.0 (8e769dcac) to v0.5.x | `<data>/project/<slug>/storage/session/{info,message/<id>,part/<id>/<msg>}`; message v1 (inline parts) and v2 (f88476644) | same test |
| J1 global JSON | v0.6.0 (f993541e0) to v1.1.65 | `storage/session/<project>/<id>.json`, `storage/message/<id>/`, `storage/part/<msg>/`; J0 copied, not moved | `global_json_storage_from_0_6_to_1_1_is_read_with_counts_and_prompts` |
| S1 SQLite | v1.2.0 (6d95f0d1, #10597) to dev 1.18.x | `opencode.db`, `opencode-<channel>.db` (a52d640c); `session`, `message`, `part`; J1 imported once and left on disk, importer removed in v1.16.0 (ca2acc4f8) | `opencode.rs`, `json_sessions_a_db_never_imported_are_listed_read_only_and_db_copies_win` |
| S2 SQLite | OpenCode 2.x, branch `2.0`, v2.0.0 (63f7ceec) to v2.0.26 (9b4ec571) | same DB file; `session_v2` (nullable title) + `session_message`; v1 tables stay | `opencode_2_sessions_win_over_their_1_x_rows_and_untitled_ones_use_the_first_prompt` |

Priority: S2, S1, J1, J0. A JSON session that a DB never imported is listed
read-only when a DB exists (a 1.1 to 1.16+ jump cannot resume it).

### Kilo CLI (OpenCode fork; Kilo-Org/kilocode)

J1 JSON v1.0.9-v1.0.25 under `<XDG data>/kilo/storage`; `kilo.db` (S1
schema) from v7.0.26 (6d95f0d14c). Same reader with Kilo names:
`kilo_reads_its_own_db_and_json_storage`.

### Pi (earendil-works/pi, formerly badlogic/pi-mono)

| Format | Versions / evidence | Layout | Covered by |
|---|---|---|---|
| v1 | all tags before v0.31.0 | header `{type:"session", id, timestamp, cwd, ...}` without `version`; entries without ids | `v1_headers_flat_custom_dirs_and_agent_dir_strays_are_read` |
| v2 | v0.31.0 (c58d5f20) | `id`/`parentId` tree | `pi.rs` |
| v3 | v0.35.0 (c6fc0845), current | role `custom`; `session_info{name}` from v0.44.0 | `the_last_session_name_wins_and_messages_are_counted` |
| Layout | `--<encoded cwd>--/<ts>_<id>.jsonl`; flat custom dirs; v0.30.0 strays in the agent dir; `~/.coding-agent` before v0.7.29 | all listed | `v1_headers_...` |
| Migration | opening an old file rewrites it in place | head print + stamp re-read | `an_in_place_rewrite_that_grows_is_parsed_again`, `a_shrunk_file_is_parsed_again_from_the_start` |

### Gemini CLI (google-gemini/gemini-cli)

| Format | Versions / evidence | Layout | Covered by |
|---|---|---|---|
| `logs.json` | v0.1.6+ | `tmp/<project>/logs.json` prompts; the only record before v0.4 | `sessions_only_logs_json_remembers_are_listed_once` |
| Checkpoints | `/chat save`; `Content[]` before v0.16, `{history, authType}` after (48e3932f) | `tmp/<project>/checkpoint-<tag>.json` | `checkpoints_in_both_shapes_are_chats_named_by_their_tag` |
| Session JSON | v0.4.0 (b5dd6f9e) to v0.38 | `tmp/<project>/chats/session-*.json` | `legacy_json_sessions_are_read` |
| Session JSONL | v0.39.0 (f7449135)+ | header, `$set`, `$rewindTo`; `kind:"subagent"` skipped | `gemini.rs` |
| Project dirs | sha256 dirs to v0.28; slug + `.project_root` from v0.29 (6fb3b090); copied, deduped by id | both read | `gemini.rs` |

### Cursor agent CLI (closed; bundle 2026.09.18, agentsview@413277eb)

`chats/<md5 cwd>/<id>/meta.json` (`isSubagent`, `hasConversation`); a chat
without `meta.json` is read from row `"0"` of `store.db`'s `meta` table (hex
JSON: `name`, `createdAt` in s/ms/us/ns, `subagentInfo`). The `blobs` table is
never read. Tests: `chats_come_from_meta_json_only`,
`a_chat_without_meta_json_is_read_from_the_store_meta_row`.

### Amp (closed; npm bundles)

Local `threads/T-<uuid>.json` up to 0.0.1774959077 (2026-03-31); later builds
keep threads on the server only. Title, `env.initial.trees[0].uri` folder,
`archived`, and `mainThreadID` subagents are read:
`thread_titles_folders_archive_flags_and_subagent_threads`.

### Qwen Code (QwenLM/qwen-code)

v1 (v0.1-v0.3, Gemini layout, 36ea986cf): `tmp/<sha>/chats/session-*.json`,
message type `qwen`, plus `logs.json`; current Qwen ignores these, listed
read-only. v2 (v0.5.0, 0a75d85ac): `projects/<sanitized cwd>/chats/<uuid>.jsonl`
and `chats/archive/`, `system`/`custom_title` records. Tests: `qwen.rs`.

### GitHub Copilot CLI (closed; npm `@github/copilot` JS through 1.0.63)

v1 to 0.0.341: `history-session-state/session_<id>_<ms>.json`. v2 0.0.342:
flat `session-state/<id>.jsonl`. v3 0.0.378+: `session-state/<id>/events.jsonl`
+ `workspace.yaml`. Tests: `copilot_cli.rs`. 1.0.64+ ship a native binary
(not read; changelog shows no layout change through 1.0.94).
`session-store.db` is not read (schema unverified).

### xAI Grok Build (xai-org/grok-build@2bdd1d6)

`sessions/<urlencoded cwd>/<uuid>/summary.json` (`chat_format_version` 0 and
1 share it); hidden sessions skipped, forks kept, subagents deeper. Tests:
`grok.rs`.

### grok-cli (superagent-ai/grok-cli@fb97af83)

In memory before 1.0. `~/.grok/grok.db` from 1.0.0-rc1 (15cb446):
`sessions`, `messages`. Tests: `grok_cli.rs`.

### kimi-cli (MoonshotAI/kimi-cli@9ab1286) and Kimi Code (MoonshotAI/kimi-code@5b93669)

kimi-cli: `sessions/<md5 path>/<id>.jsonl` (v0.32-v0.58),
`<id>/context.jsonl` (v0.59, 50a663a), `wire.jsonl` (v0.64, b0d3843),
`state.json` replacing `metadata.json` (v1.14.0, 600ff8f); folders from
`kimi.json`. Kimi Code: `sessions/wd_*/session_<uuid>/state.json` +
`session_index.jsonl` (tombstones). Kimi Code imports kimi-cli chats under new
ids with no link field, so both stores are listed. Tests: `kimi.rs`.

### goose (block/goose@241061468a8d)

JSONL `<id>.jsonl` (to v1.9.x; metadata line from v1.0.11, 9ae90455) and
`sessions.db` from v1.10.0 (dc292883, schema v1-v16). The import keeps the
JSONL files; the DB row wins. Tests: `goose.rs`.

### Factory Droid (closed; binary 0.237.0)

`<enc cwd>/<uuid>.jsonl` (+ `.settings.json`) and legacy flat `<id>.jsonl`;
line 1 `session_start` (rewritten in place on rename); `callingSessionId`
subagents skipped. Tests: `droid.rs`.

### Cline, Roo Code, Kilo Code extension

Cline (cline/cline@fa840c7): A1 to 3.27 (index only in VS Code
`state.vscdb`, tasks in `tasks/<id>/ui_messages.json`, `claude_messages.json`
before 2.2.0), A2 3.28.0-3.89.2 (`state/taskHistory.json`, 2ecb87ac5), B (CLI
3.0.0, extension 4.0.0: `db/sessions.db`). Roo (b867ec9): `tasks/_index.json`
and `tasks/<id>/history_item.json` from 3.49.0 (b598efb42). Kilo Code
legacy: globalStorage tasks and `~/.kilocode/cli/global/global-state.json`.
Tests: `vscode_tasks.rs`.

### Crush (charmbracelet/crush@cd807036)

Per project `<data_dir>/crush.db` (`sessions`, `messages`; times in seconds);
global `projects.json` from v0.25.0 names the data dirs. Tests: `crush.rs`,
`pi_reads_the_session_dir_setting_and_crush_reads_its_project_index`.

### Augment Auggie (closed; npm 0.36.0), Continue (continuedev/continue@5522c6f), OpenHands CLI (OpenHands-CLI@954f2ba)

Auggie `sessions/<id>.json` (backups skipped). Continue `sessions.json` index
+ `<uuid>.json`. OpenHands `conversations/<hex>/base_state.json` +
`events/event-*.json`. Tests: `auggie.rs`, `continue_dev.rs`, `openhands.rs`.

## Not supported, with the reason

| Harness or store | Reason |
|---|---|
| Aider | One markdown log per repo (`.aider.chat.history.md`), no global index and no ids. |
| Warp | Closed source; store in a protected Group Container. |
| Amp threads after 2026-03-31 | Server only; reading them needs `amp threads list` with the user's login. |
| OpenCode experimental Go (v0.0.1-v0.0.52) | A different program. |
| Pi experimental `session.sqlite` runtimes | Not the default; schema unverified. |
| VS Code `state.vscdb` (Cline A1, Roo before 3.49, Kilo extension index) | A shared editor DB; the task dirs give the same chats. |
| Copilot `session-store.db` | Schema unverified (bundled docs only); the session files give the same chats. |
| Custom DB files: `OPENCODE_DB`, `KILO_DB`, `CODEX_SQLITE_HOME`, `CLINE_DB_DATA_DIR`, Roo `customStoragePath`, Qwen `advanced.runtimeOutputDir`, Crush projects used only before v0.25.0 | A root is a directory; these name files or settings outside it. Add them as user roots. |

## Resume commands

Verified: Claude and Codex (acpmux adopt), `opencode -s`, `pi --session`,
`gemini --resume`, `cursor-agent --resume`, `amp threads continue`,
`goose session --resume --session-id` (goose-cli `cli.rs` at 241061468a8d).
Unverified, kept because a wrong command only fails in its own tab:
`kilo -s`, `qwen --resume`, `copilot --resume`, `droid --resume`. Everything
else opens read-only.
