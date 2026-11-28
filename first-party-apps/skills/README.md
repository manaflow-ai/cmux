# Skills and MCP (`cmux/skills`)

Lists, installs, turns on and off, and removes the skills (SKILL.md folders) and MCP servers of each agent (Claude Code, Codex, OpenCode, Gemini CLI), for the current project or everywhere. Each item shows its source (git repository and ref, the store, a local folder, or the agent that added it), what it asks for in cmux scope words (`process:execute`, `net:api.github.com`, `fs:read:project`) with a risk tone, and the sandbox profile it runs under. Every change is planned first: the app shows the exact edit to the agent's own config file as a diff, inline or in the Diffs app, and writes nothing until you tap Apply.

Status: prototype on today's app runtime (preview harness and bun FakeHost). Every data and write op is proposed (below). Manifest v2: `cmux-app.v2.json` and `catalog/`; the proposed host ops the app calls are in `proposed/host-catalog.json`, not in its catalog.

## Contributions

| Kind | Id | What |
| --- | --- | --- |
| Sidebar section | `skills` | Counts of skills and servers, items that run commands without a sandbox, and "1 change to review" while a plan waits. Each row opens the pane. |
| Pane kind | `skillsHub` | The manager (three designs, below), with "Install skill" (git URL, owner/repo, `store:publisher/name`) and "Add MCP server" (`name command…` or `name https://…`) fields. |
| Commands | `openSkills`, `reload` (palette, section menu), `cycleVariant` (palette, DEV/NIGHTLY) | |

## Scopes

| Scope | Why |
| --- | --- |
| `skill:read`, `mcp_server:read` | list items; env and header values never reach the app, only their names |
| `workspace:read` | the current workspace's folder as a root handle (project scope) |
| `skill:write`, `mcp_server:write` (optional) | apply a reviewed plan from a tap (origin user) |

## How a change is written

1. The app calls the op with `dry_run: true` (`mcp_server.add`, `skill.install`, `*.enable|disable|remove`). The owner reads each affected config file as a document, applies the change, and returns a diff resource (`diff_…`, V5) whose files carry their base revisions, plus a patch per file for the inline preview, what the item asks for and its sandbox profile.
2. The preview never shows a secret: env, header and secret-named values are masked, and JSON previews show only the server tables (`~/.claude.json` holds account state too).
3. Apply sends `diff.decide {diff, decisions: [{decision: "accept"}]}` with the tap's gesture. The owner writes every file atomically only if each still has its base revision. If an agent CLI wrote one of them in between, the answer is `diff.stale`; the app plans the same intent again once and shows the new diff with a note.
4. "Open in Diffs" sends `ui.open {interface: "cmux.diff.renderer/1", props: {diff}}`, so the user's diff renderer (the Diffs app) can show the same plan and accept it too.

The merge rules are pinned by a TypeScript reference model (`src/model/mcp.ts`) and the conformance vectors `test/merge-cases.json` (19 cases) that the native owner must pass: JSON keeps every other key, its order, the indent and the final newline, and refuses files with comments (JSONC) instead of dropping them; TOML edits only the server's own tables line by line, so every other byte stays. An agent with an `enabled` flag (Codex, OpenCode) is turned off with it; for the others cmux parks the entry under `_cmuxDisabledMcpServers` in the same file and moves it back on enable.

## Variants (DEV/NIGHTLY setting `variant`, palette "Next Skills Variant")

| Variant | Design |
| --- | --- |
| `unified` (recommended) | one list of skills and servers where the same name across agents is one row, kind and scope chips, the selected item's details (source, requests, sandbox, secret names, a Turn On/Off per agent), the plan inline with context lines |
| `byAgent` | agent chips, then Skills and MCP Servers of that agent with Turn On/Off per row; the plan shows as files with counts and is meant to be read in the Diffs app |
| `byScope` | Everywhere and This project sections, agents as text per row, a risk badge; the plan shows only its changed lines |

Recommendation: `unified`. A skill or server is usually installed for several agents at once, and the questions are about the item ("what does github run, with which secret, unsandboxed?"), which one row with one detail answers. Strongest objection: the inline diff, the list and the detail share one pane with no scroll view, so a four-file plan pushes the list down; `byAgent` keeps the list stable and sends the diff to the Diffs app.

## Proposed operations

Owner: the session host of the machine that has the files (V3 document host), next to the `agent_cli.*` ops of `cmux/agents`. The operation-catalog form is `proposed/host-catalog.json`.

| Op | Params | Result | Owner | Risk | Scope | Events | Why existing ops do not suffice |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `skill.list` | `{machine?, agent?, roots?}` | `{skills: [{id: skl_…, name, description, agent, scope, root?, enabled, source, requests, sandbox, path_label}]}` | session host | read | `skill:read` | `skill.watch` | nothing reads agent skill folders |
| `skill.install` | `{agents, scope, root?, source: {git, ref?, path?} \| {store}, dry_run?}` | plan `{diff, title, files, requests, sandbox}` | session host | execute (adds code agents run), origin user | `skill:write` | `skill.watch` | the fetch (git clone, store download) and the scan of what the skill asks for must run in the owner, not the app |
| `skill.enable`, `skill.disable`, `skill.remove` | `{id, agent, scope, root?, name, dry_run?}` | plan, or `{applied}` | session host | mutate-shared; remove destructive (to the trash) | `skill:write` | `skill.watch` | same |
| `mcp_server.list` | `{machine?, agent?, roots?}` | `{servers: [{id: mcp_…, name, agent, scope, root?, enabled, transport, command_label?, url?, env_keys, source, requests, sandbox, path_label}]}` | session host | read | `mcp_server:read` | `mcp_server.watch` | the agents' config files hold secrets; the owner returns names only |
| `mcp_server.add` | `{agents, scope, root?, name, entry, dry_run?}` | plan | session host | execute (the agent will start that command), origin user | `mcp_server:write` | `mcp_server.watch` | per-agent formats and secret handling belong to the owner |
| `mcp_server.enable`, `mcp_server.disable`, `mcp_server.remove` | `{id, agent, scope, root?, name, dry_run?}` | plan | session host | mutate-shared; remove destructive | `mcp_server:write` | `mcp_server.watch` | same |
| `skill.watch`, `mcp_server.watch` (streams) | `{machine?}` | `{agent, scope, root?, path_label}` | session host | read | read scopes | | agent CLIs edit these files too; no polling |
| `workspace.root` | `{workspace}` | `{root: root_…, label}` | session host | read | `workspace:read` | `workspace.changed` | a project scope needs the folder as a handle, never a path |
| `diff.decide` | `{diff, decisions}` | `{applied}` or `diff.stale` | diff producer (session host) | mutate-shared, origin user | write scope of the producing op | `diff.changed` | V5 op shared with the Diffs app: one accept path for every producer |
| `ui.open` | `{interface, props}` | | shell | mutate-own, gesture | | | open the plan in the user's `cmux.diff.renderer/1` |

Proposed next (not built): `mcp_server.set_sandbox {id, profile}` wraps a server's command so cmux runs it under a sandbox profile (`none | standard | contained | complete`), planned and reviewed like any other change; secret values for a new server go through a host sheet into a credential handle (`cred_…`) that the owner writes, never through the app.

## Platform gaps (most important first)

1. No owner for agent configuration on each machine (see `cmux/agents`); the three agent-tools apps need one shared owner.
2. No diff resources or `diff.decide` (V5) and no "plan as diff" convention: a dry run that returns a `diff_…` with base revisions per file, accepted atomically, would serve every app that writes files it does not own.
3. No secure input: a server's API key cannot be entered anywhere; it needs a host sheet that returns a credential handle.
4. No `ui.open` for interfaces (and no `Embed` scene node), so "Open in Diffs" and an embedded diff do not work today.
5. No `workspace.root`: a workspace's folder is not available as a root handle.
6. Scene: no ScrollView (long plans push the list off the pane), no segmented control (chips are tappable texts), no multi-line field, no confirmation for destructive actions (Remove plans a diff, which doubles as the confirmation).
7. The scope grammar does not know `skill:*` and `mcp_server:*` (validator warnings).
8. The sandbox profile of a third-party MCP server or skill script has no enforcement path yet (permissions model section 5 covers apps only).
9. Palette commands carry no gesture token and take no arguments, so "Add MCP Server…" cannot be a palette command.

## Layout and checks

`src/model/` (agent table, MCP merge reference model with redaction, line diff and unified patch, patch parser, items and filters, the planned-change state machine, install source parsing), `src/store.ts`, `src/actions.ts`, `src/views/` (section, variants, review card, shared parts), `src/l10n.ts` + `strings/`. No third-party code.

```bash
bun cmux-tui/crates/cmux-app-host/tools/pack.ts first-party-apps/skills
bun cmux-tui/crates/cmux-app-host/tools/validate-manifest.ts first-party-apps/skills
bun test first-party-apps/skills/test
bun first-party-apps/skills/test/merge-cases.ts   # regenerates test/merge-cases.json
```

`preview/*.json` are preview-harness fixtures (invented servers, skills and config files; the plans in them are computed with the reference merge); `preview/make-fixtures.ts` regenerates them.
