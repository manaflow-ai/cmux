# Diffs (`cmux/diffs`)

Review changes in cmux: the working tree against HEAD, two refs, an agent's proposed diff (a feed `review` request), or a run's diff. Inline or side by side, comments on lines, accept or reject per hunk or per file. Decisions go to the diff's owner (git stages or restores; an agent's proposal applies or drops), always from a user tap.

Status: prototype on the current app runtime. Every data and action op it uses is proposed (see below), so today it shows which op is missing. Manifest v2: `cmux-app.v2.json` and `catalog/` (section Manifest v2).

## Interfaces

- Implements `cmux.diff.renderer/1` (pane kind `diff`, declared as `x-cmux-implements` until the manifest has `implements`).
- Consumes `cmux.editor/1`: each file body is an embed of the user's editor app (default `cmux/codemirror`, setting `editorApp`) through the proposed `ui.embed.create` and a proposed `Embed` scene node. Without an editor app, or when the embed fails, the app draws its own inline or side-by-side diff with the scene API (`src/views/filediff.ts`).
- Consumes `cmux.diff.source/1` through diff resources (`diff_…`) and git ops.
- `src/interfaces/*.ts` are typed definitions of the proposed interfaces (`cmux.editor/1`, `cmux.diff.renderer/1`, `cmux.diff.source/1`, documents, git, embeds, the web pane bridge). The same files are vendored, byte for byte, in `first-party-apps/{diffs,codemirror}/src/interfaces`; a test keeps them identical until the platform generates them.

## Contributions

| Kind | Id | What |
| --- | --- | --- |
| Sidebar section | `changes` | The current workspace's repository: branch, staged and unstaged files with +/- counts. Tap opens the diff pane at that file. Reloads on `git.changed` and `workspace.changed`, no polling. |
| Pane kind | `diff` | The diff renderer (scene). |
| Commands | `openChanges` (palette), `openDiff` (CLI/MCP: repo, base, head), `review` (item, diff or run), `reviewLatest` (palette), `toggleLayout` (palette), `cycleVariant` (palette, DEV) | |
| MCP | `diffsTools` | the commands as tools |

## Scopes

| Scope | Why |
| --- | --- |
| `workspace:read` | find the repository of the current workspace |
| `git:read` | git status and diffs |
| `diff:read` | open diffs that agents and runs propose |
| `feed:read` | open the review request an agent sent |
| `git:write` (optional) | Stage or Discard from a tap |
| `diff:write` (optional) | record accept, reject and comments |
| `feed:write` (optional) | send the review answer |
| `embed:run` (optional) | show file bodies with the user's editor app |

## Variants (DEV/NIGHTLY setting `variant`, palette "Next Diffs Variant")

| Variant | Design |
| --- | --- |
| `split` (recommended) | file list on the left, the selected file's diff on the right |
| `stream` | every file in one continuous scroll, each collapsible |
| `review` | review mode for proposals: title, producer, checklist, counts, Accept All, Reject All, Submit Review with the verdict; files stacked with per-file and per-hunk decisions |

Recommendation: `split` for git changes and `review` automatically for a feed review request (the `review` command switches to it). Strongest objection to `split`: in a narrow pane the 230 pt file list takes width that a side-by-side diff needs, and with no ScrollView in the scene the right column clips at the pane height.

## Proposed operations

| Op | Params | Result | Owner | Risk | Scope | Events | Why existing ops do not suffice |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `git.status` | `{workspace? \| repo?}` | `{repo: {repo, name, branch, head}, files: [{path, status, staged, additions, deletions}]}` | session host | read | `git:read` | `git.changed {repo}` | no git ops; terminals are not an API |
| `git.diff` | `{repo, base?, head?, paths?, include_patch?}` | diff resource (producer git) with unified patch | session host | read | `git:read` | `git.changed` | same |
| `diff.get` | `{diff, include_patch?}` | diff resource | diff producer (session host record) | read | `diff:read` | `diff.changed {diff}` | agent and run diffs have no home today |
| `diff.decide` | `{diff, decisions: [{path, hunk?, decision}]}` | `{applied, diff}` | diff producer (git: stage/restore; agent: apply/drop) | mutate-shared, origin user | `diff:write` (+ `git:write` for git) | `diff.changed`, `git.changed` | one op for every producer instead of per-producer verbs |
| `diff.comment.add` | `{diff, path, line, side, body}` | comment | diff producer | mutate-shared | `diff:write` | `diff.changed` | no comment store |
| `diff.file.read` | `{diff, path, side}` | `{text}` | diff producer | read | `diff:read` | | an embedded editor reads one side of a file by handle |
| `feed.get`, `feed.list` | `{item}`, `{kind, state, limit}` | feed item(s) | feed owner | read | `feed:read` | `feed.changed` | feed ops are not in the app catalog yet |
| `feed.answer` | `{item, value: {verdict, notes}}` | item | feed owner | send to the poster, origin user | `feed:write` | | answers the agent's `review` request |
| `automation.run.get` | `{run}` | `{diff?}` | automation owner | read | `automation:read` | | a run's published diff |
| `document.read` | `{doc, revision}` | `{text}` | document host | read | `document:read` | | documents input (conflict compare) |
| `ui.embed.create`, `ui.embed.update` | `{interface, props, prefer?, minHeight?}`, `{embed, props}` | `{embed, app, capabilities}` | shell | mutate-own | `embed:run` | `ui.embed.event` | composition by embedding (C3) |
| `ui.open` | `{interface, props \| target}` | | shell | mutate-own, gesture | | | Open File with the user's editor |
| `app.pane.open` | `{kind, input, focus_path?}` | `{pane}` | shell (workspace store) | mutate-own, gesture | `workspace:write` | | open this app's pane with an input |
| `app.settings.set` | `{key, value}` | | config layer | mutate-own | | `settings` push | persist variant and layout |

## Manifest v2

`cmux-app.v2.json` is the manifest v2 that the daemon's app supervisor loads; it passes the one validator (`cmux-tui/crates/cmux-app-manifest`). It declares the same app as `cmux-app.json`: `runtime.main` `dist/main.js`, `cmux.section/1` (`renderChanges`), `cmux.pane/1` and `cmux.diff.renderer/1` (both `renderDiffPane`, inputs in `options.inputs`), `consumes` `cmux.editor/1` and `cmux.diff.source/1`, handles `diff` and `document`, and the catalog fragment `catalog/diffs-catalog.json`. Every v1 command is one catalog op of family `diffs` (owner `app:cmux/diffs`, `export` names the JS function, CLI `apps run cmux/diffs <verb>`, palette title only for palette commands, MCP as v1 exposed it). The DEV/NIGHTLY `variant` setting is the `variants` block. `cmux-app.json` stays for today's in-app runtime.

The v2 schema cannot hold these parts of the app, so the manifest leaves them out:

1. Scope `embed:run` (show file diffs with your editor app): not in the v2 scope grammar. Embedded editors wait for a grammar entry.
2. Setting `editorApp` as an app-id typed setting bound to `cmux.editor/1`: settings are plain JSON Schema, so it stays a string.

Platform gaps found by the earlier v2 sketch (still open):

- No Embed scene node in the v2 scene vocabulary (V7 lists List, Section, Row, Detail, Form, ActionPanel, Table, Meter): V4 embeds need a placement node.
- No generic hunk decision op across producers: V5 names git.stage/apply only; diff.decide routes accept/reject to any producer.
- No diff.file.read for an embedded editor to read one side of a diff resource.
- No pane open with input (app.pane.open {kind, input}) or pane input in the mount context.
- No ScrollView and no vertical alignment for HStack in the scene (split view clips at the pane height).
- No confirmation primitive for destructive scene actions (Discard uses a second tap).

Update (2026-10-03): the manifest v2 extensions (app-platform.md 12.5) now hold the items above that this app needed; `cmux-app.v2.json` and its catalog declare them (scopes, handles, keyboard, gestures, presets, requires, lifecycle, documents, openWith, notices, drag/drop and `consumes` as applicable). Items that depend on missing runtime support (embed node, pane-routed commands, native servers) stay open.

## Platform gaps (most important first)

1. No interfaces or embeds: no `implements`/`consumes` in the manifest, no `ui.embed.*`, and no `Embed` scene node to place a mount. The app feature-detects a global `Embed` builder and otherwise uses its own scene diff.
2. No git ops and no diff resources (owner, decisions, comments, `diff.propose` for agents, `diff.publish` for runs).
3. No pane input: a pane kind mount has no `input`; `app.pane.open` does not exist, so a mounted pane follows the last opened input.
4. Scene: no ScrollView, no vertical alignment for HStack (the split view uses fill-height columns with a Spacer), no translucent token fills (a `Rectangle` at 14 % opacity under each changed line), no confirmation for destructive actions (Discard needs a second tap), and the 4096-node mount limit caps the built-in diff (setting `fallbackLines`, "Show more").
5. No `onCleanup`: event subscriptions and embed handles live until the app stops.
6. Commands have no context: `review` cannot know the gesture origin (V11 gesture tokens) and palette commands cannot prompt for arguments.
7. The scope grammar rejects `feed:answer` and `ui:embed`; the app uses `feed:write` and `embed:run`.
8. `app.settings.set`, `x-cmux-devOnly`, app l10n (`strings/*.json` are bundled into `dist/main.js`) and the mount locale are missing.
9. Typings: `CmuxError` has no constructor in `cmux-app.d.ts`.

## Layout and checks

`src/model/` (unified diff parser, Myers line diff, review model: decisions, rollup, side-by-side rows, comments, verdict), `src/source.ts` (input -> resource), `src/session.ts` (per-pane state), `src/views/` (section, variants, file diff, decisions), `src/commands.ts`, `src/l10n.ts` + `strings/`. No third-party code.

```bash
bun cmux-tui/crates/cmux-app-host/tools/pack.ts first-party-apps/diffs
bun cmux-tui/crates/cmux-app-host/tools/validate-manifest.ts first-party-apps/diffs
bun test first-party-apps/diffs/test
```

`preview/*.json` are preview-harness fixtures (invented repository); `preview/make-fixtures.ts` regenerates them.
