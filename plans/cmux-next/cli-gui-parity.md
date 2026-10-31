# cmux NEXT: CLI parity with the GUI

Issue: https://github.com/manaflow-ai/cmux/issues/23026 (see also
https://github.com/manaflow-ai/cmux/issues/23016). Goal: an agent can do from the
`cmux` CLI (and MCP) what a person does in the GUI or terminal, without moving the
person's focus.

## How actions reach the CLI

Every app action is a descriptor in `CmuxNextActions/Catalog`. Its `surfacePlan.cli`
is `.offered` (a `cmux <cliName>` verb through `action.run`) or `.exempt(reason)`.
`isPersonOnly` refuses a socket run whatever origin the caller claims. Daemon objects
(workspaces, panes, tabs, terminals) are the daemon's verbs; acpmux chats are
`cmux acp` and `cmux agents chat`.

## Audit (2026-10-20, origin/feat-cmux-next 194c879d10cad)

CLI exemptions by reason: guiOnly 51, clipboard 10, liveInput 8, familyMember 7,
devOnly 6, focusMove 4, ownerVerb 2. Person-only actions over the socket included
`window.screenshot`, `pane.screenshot`, `tab.screenshot`, the browser captures,
tool-permission answers, password and CSV imports, extension load-unpacked, design
mode and certificate-warning proceed.

Gaps the issue named, and what this change does:

| GUI action | Before | Now |
| --- | --- | --- |
| New Agent Chat (harness, model, effort, permissions) in a given workspace or pane, unfocused | `agent new-chat` needs a mounted pane ("That pane is no longer open"); `acp new` + `agent open` only in a new workspace | `cmux agents chat new [--workspace W\|--pane P] [--harness] [--model] [--effort] [--mode] [--policy] [--cwd] [--name] [-- prompt]`, MCP `agents_chat_new`; `agent open --pane P\|--workspace W` |
| Send to an existing chat | `agents chat send` | unchanged; `agents chat continue <chat> [text]` nudges |
| Read a chat's state | transcript only (`agents chat read`) | `agents chat state <chat>`, MCP `agents_chat_state` |
| Stop a chat's turn | `cmux acp session cancel` (any chat, no session scope) | `agents chat interrupt <chat>`, MCP `agents_chat_interrupt` (this session's chats, never the caller's own) |
| Copy the latest assistant code block | person-only pasteboard action (`agentPane.copyLastCodeBlock`) | `agents chat read <chat> --last-code-block`, MCP `agents_chat_read(last_code_block: true)` returns the latest complete fenced block with the same secret masking as transcript text |
| Screenshot a pane or tab | person only | agents may capture terminal and page panes and tabs (the window alone, no overlay or floating window); browser and agent-chat pixels stay refused (`cmux browser page screenshot` and `cmux agents chat read` mask secrets) |

A Chief turn keeps `agents_chat_send`, `agents_chat_read` and `agents_chat_state`
among its cmux tools (https://github.com/manaflow-ai/cmux/issues/25571), so a Chief
messages the chats the person started, a restored chat no tab has shown yet included;
`agents_chat_new` and `agents_chat_interrupt` stay denied to it.

`window.screenshot` stays person only: a window can show a browser page beside
anything else.

Code-block reads preserve the normal transcript page and cursor. The extra field is
`null` when no complete assistant fence exists. Code is secret-masked before it is
bounded to 8 KiB (less when JSON escaping needs it); cut results carry `truncated: true`.
The lookup reads backward without attaching to the chat or marking it seen. If its
20-page / 8 MiB scan cannot establish a result, it refuses with
`chat.code_block_unavailable` rather than reporting an older block as the latest.

## Remaining gaps (next steps)

GUI-only actions with no headless equivalent yet, by what they would need:

- Chat view controls with an owner verb to point at: `agentPane.switchModel`
  (`cmux acp session set model=…`), `agentPane.createCheckpoint` (`git.checkpoint.*`),
  `agentPane.continueIn` (acpmux handoff). Their refusals should name the verb.
- Transcript stepping (`agentPane.previousTurn` and the rest), `files.open`,
  `passwords.open`, `stats.show`, `chief.openUsage`, `server.showPanel`: views of
  data the CLI already reads; they only move the person's view.
- Sidebar view toggles (`sidebar.groupBy.*`, `sidebar.density.*`, section hide/show):
  settings writes; `cmux settings set` covers them once their keys are listed.
- Tool-permission approval stays a person's (a socket caller could approve its own
  request); agents deny or answer questions with `agents dialog answer`.
