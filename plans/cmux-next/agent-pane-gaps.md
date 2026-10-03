# Agent pane gaps (package P7)

Status: plan, 2026-10-03. Owner: P7 lead. Spec: acp-ui.md (S5, S8) and operation-catalog.md section 7.1 in the spec repo. Covers spec-coverage.md package P7.

Scope boundary (coordinator, 2026-10-03): the ACP lead builds the `debug.agent_pane` socket actions and the ACP end-to-end test. P7 does not build them. P7 uses them for its end-to-end proof when they land.

P7 owns four things, in this order:
1. `git.files.search` on the session host, so @ mentions and the files palette get results.
2. `git.commit` and `git.push` on the session host, and the Changes pane actions that call them.
3. The last-turn diff op.
4. The Milkdown file editor in `webviews/src/markdown-editor`, with a round-trip corpus.

## 1. File search (`git.files.search`)

Today the page calls `file.search {path, query, limit}` (webviews/src/agent-session/acpmux/fileSearchModel.ts). In acpmux mode `AcpmuxDirectClient.fileSearch` sends it to acpmux over the WebSocket, and acpmux has no handler, so it fails with method not found. In native mode the Swift host answers `unsupported`.

Plan:
- Rust: new read op `git.files.search` in cmux-tui-core `git_ops/files.rs`, beside `git.diff`. Same target rules as 7.1 (`path` or a terminal, tab, pane, screen or workspace selector), the same read runner (no `GIT_*` environment, no fsmonitor, deadline, bounded output).
- Input: `query` (string, may be empty), `limit` (1 to 200, default 50).
- Candidates: `git ls-files -z --cached --others --exclude-standard` from the repository root, so ignored files are left out and new files are found. When `path` names a folder below the root, only files under it are candidates, and result paths stay relative to the root (`root` is in the reply).
- Ranking (in Rust, deterministic): case-insensitive subsequence match; the score prefers matches in the file name, matches at word starts (after `/`, `_`, `-`, `.`, or a lower-to-upper case change), consecutive runs, and shorter paths. Ties sort by path. The reply gives each match's character indexes for highlighting.
- An empty query returns `{root, results: []}`. The page shows recent files from its own state.
- Output: `{root, results: [{path, matches?}], truncated?, total_candidates}`. `truncated` is true when more files matched than `limit`, or when the candidate list hit the cap (200,000 paths or 32 MiB of `ls-files` output).
- Errors: the 7.1 codes. Outside a repository is `operation.failed` with reason `not_a_repository` (the same as `git.diff`).
- Identify capability: `git-files-search-v1`.
- CLI (generated from `cli.path`): `cmux git files <query> [--limit N] [--path P | --workspace ...]`. MCP group `git`.
- Page: `fileSearch` goes through the same route as `git.diff` (`gitRoute`: native host, or the daemon in mock mode), not acpmux. The Swift host maps the page method `file.search` to the session host op `git.files.search` with the chat's folder as `path`, through the existing `GitResourceClient`. The page reads `not_a_repository` from `details` for its "not in a repository" state.
- Tests: Rust unit tests for ranking and match indexes; integration tests on a temporary repository (tracked, untracked, ignored, subfolder `path`, no repository, limit and truncation, non-UTF-8 names skipped); Swift request mapping tests; page test against the mock daemon in the new shape.

## 2. Commit and push

Both are mutations owned by the session host, with idempotency keys and the per-session `resource_mutations` ledger that checkpoints use.

`git.commit`:
- Input: target, `message` (1 to 64 KiB), `paths?` (stage exactly these, relative to root, literal pathspecs), `all?` (stage every tracked change, like `git commit -a`), `include_untracked?` (with `all`), `amend?` false, `expected_head?` (refuse with `head_moved` when HEAD changed since the pane read it), `idempotency_key`.
- With neither `paths` nor `all`, it commits the index as it is (the Staged scope).
- Output: `MutationResult<{root, commit, branch?, parent?, summary, files_changed, additions, deletions}>`.
- Hooks: the user's hooks run, the same as `git commit` in a terminal (pre-commit, commit-msg). `no_verify?` false skips them. The run has a deadline of 120 s, because a hook can be slow.
- Failures (`operation.failed`, `details.reason`): `not_a_repository`, `nothing_to_commit`, `head_moved`, `merge_in_progress` (also rebase and cherry-pick), `hook_failed` (with the hook's stderr, cut at 16 KiB), `identity_missing` (no user.name or user.email), `index_locked`, `git_failed`.
- Risk class: `write` (local, reversible). An agent call through MCP is gated by the same approval rules as other local writes.

`git.push`:
- Input: target, `remote?` (default: the branch's upstream remote, else `origin`), `branch?` (default: the current branch), `set_upstream?` (default true when the branch has no upstream), `expected_head?`, `idempotency_key`. No force push in this op.
- Git runs with `GIT_TERMINAL_PROMPT=0` and no askpass, so it never waits for input. The user's credential helper and SSH agent work as in a terminal.
- Output: `MutationResult<{root, remote, branch, upstream, pushed_commit, previous_remote_commit?, created_upstream}>`.
- Failures: `no_remote`, `detached_head`, `rejected_non_fast_forward` (the pane offers Pull, which is not in this op), `rejected_by_remote` (hook or protection, with the remote's message), `auth_failed`, `network_failed`, `timed_out` (120 s), `git_failed`.
- Risk class: `external` (it changes state on another machine). Replays with the same key return the first result; a second push of the same commit is a no-op success.

Pane: the Changes toolbar gets Commit (message field, Staged or All toggle) and Push (shows ahead count from `git.status`). Busy, success and each failure reason have localized states. Both actions are in the app action catalog (`agentPane.git.commit`, `agentPane.git.push`) on every surface, and the catalog is regenerated with `CMUX_UPDATE_ACTION_SURFACES=1 swift test --filter ActionCatalogTests`.

## 3. Last-turn diff

The spec says last turn needs a turn boundary that the session host owns. Checkpoints (#16984) already give that boundary.

Plan:
- New read op `git.checkpoint.diff {target, from, to?, paths?, include_patch, max_patch_bytes?, max_files?}`. `from` and `to` are checkpoint ids. With no `to`, it compares with the working tree. The output is the `git.diff` output with `scope: "checkpoint"`, `from` and `to`, so the Changes view renders it with no new code path.
- The turn boundary: the agent pane (or acpmux, if the ACP lead prefers) creates a checkpoint before it sends a prompt and records its id on the turn. "Last turn" is that checkpoint against the working tree while the turn runs, and against the next checkpoint after it ends.
- This needs agreement with the ACP lead on who calls `git.checkpoint.create` at a prompt (see the questions below).

## 4. Markdown file editor

- `webviews/src/markdown-editor`: Milkdown (`@milkdown/kit`, exact version pins), restyled with cmux theme tokens. No toolbar; slash menu and selection bubble only.
- Round-trip corpus first: `webviews/src/markdown-editor/corpus/` with real files (cmux docs, READMEs, plans, agent outputs, GFM edge cases, tables, footnotes, math, frontmatter, HTML blocks). A bun test asserts parse then serialize is byte-identical, or equal after a normalization listed in `corpus/NORMALIZATIONS.md`.
- Preserve-format serializer: record source markers per node during parse (bullet character, emphasis character, fence style and length, ordered-list start and delimiter, heading style, link style, hard-break style) and reuse them on serialize. Unknown syntax, frontmatter and math are raw nodes that serialize verbatim.
- Edit-scoped writes: save serializes only the top-level blocks the user changed and splices them into the original text, so untouched blocks keep their bytes.
- Format-changes indicator: when a save would change bytes outside the edited blocks, the editor shows it and lets the user cancel.
- Opening markdown files from the Changes view and from `file.open` uses this editor. Coordinate with lane 3 (editor apps) for the file pane host.

## Landing

- Rust changes are under `cmux-tui/` and need a cmux-tui landing window from main, a review subagent (daemon and protocol), and exact-head `cargo check --all-targets`, fmt, clippy and the touched crate tests on a Testbox.
- New ops regenerate `resource-operations-v2.json`, the SDK bindings and the per-language count tests in the same push.
- The app pin moves to a cmux-tui SHA that serves the new ops before the pane depends on them; the pane gates on the identify capabilities.
- End-to-end proof on cmux-lawrence-2 with the ACP lead's `debug.agent_pane` actions: an @ mention returns results; commit and push work from the Changes pane against a scratch repository with a local bare remote.

## Questions for the coordinator

- Op name: the spec says `git.files.search`; the page says `file.search`. Recommend: the catalog op is `git.files.search`, and `file.search` stays only as the page-to-host method name.
- Who creates the turn-start checkpoint: the pane through the native host, or acpmux. Recommend: acpmux, because it owns turns and works with no pane open; it calls the session host op.
- Commit hooks: recommend running them (as in a terminal), with `no_verify` as an explicit opt-out.
