---
name: cmux-agent-memory
description: "Set up, check or use the long-term memory that cmux NEXT's Codex and Claude Code sessions share (optchat-chief agent-memory, the cmux-agent-memory MCP server), on one machine or several. Use when turning agent memory on, choosing the machine that owns the index, connecting another machine or a server without the app, wiring an agent cmux does not start, searching or saving a memory from a shell, or when memory_search answers from the wrong machine."
---

# Shared agent memory

Agents cmux NEXT starts can search one long-term memory: every Claude Code project
memory file, Codex's memories, decision folders you name, and the notes agents save
with `memory_remember`. One machine owns the index; the others reach it through
`cmux remote`, the transport cmux already uses for remote workspaces. Hits are recall,
not authority: the repository's `AGENTS.md` and `CLAUDE.md` win.

## Turn it on (the machine that will own the index)

Set the key in `~/.config/cmux/cmux-next.json` (see [configuration](../../docs/configuration.md#agentsmemory)):

```jsonc
{ "agents": { "memory": { "enabled": true } } }
```

New agent sessions get the `cmux-agent-memory` server. Check the index from a shell with
the app's own binary:

```bash
"/Applications/cmux NEXT.app/Contents/Resources/bin/optchat-chief" agent-memory sync
```

Expect `indexed N memory entries into ~/.cmux/agent-memory`. `agent-memory sources`
lists what went in. To add decision records or team notes, list their folders in
`agents.memory.sources`.

## Connect another machine

On each other machine, name the owner as a `cmux remote` route and turn memory on:

```jsonc
{ "agents": { "memory": { "enabled": true, "owner": "ssh://studio" } } }
```

`ssh://HOST` uses your ssh config, so aliases, `ProxyJump` and your usual key work;
no `authorized_keys` entry is added for memory. An enrolled, relay or WireGuard route
works the same and needs no sshd. Put route options in `agents.memory.ownerArgs`
(`["--daemon", "FINGERPRINT"]`, `["--no-install"]`). The first call to a new owner
starts a cmux sidecar there (installing `~/.local/bin/cmux-tui` unless `--no-install`);
later calls reuse it and take under a second.

Check from the connected machine:

```bash
optchat-chief agent-memory search some distinctive words
```

A hit list is the owner's. A first line saying the owner "did not answer" means the
route failed, and this machine's own index answered. The line carries the ssh or
cmux error. After a failure, calls skip the owner for a minute and answer locally at
once. A relayed call gives up after 40 seconds in all (Codex stops waiting for a tool
after 60, and cmux cannot raise that for the sessions it starts); a dead route gives up
after 15. Pass a longer `--connect-timeout-seconds` in `ownerArgs` for a slow first
install. Notes are never saved locally when the owner is down. The agent gets an error
instead, so notes do not split across machines. When the owner stopped answering after
it got the note, the error says the note may have been saved: search for it first.
Saving the same text again keeps one copy.
`search --json` prints the same warning on stderr and keeps stdout JSON.

## A machine without the cmux NEXT app

A Linux server has no app bundle. Build `optchat-chief` (`cargo build --release` in
`Native/OptChat/optchat-chief`), put it in `~/.local/bin`, and keep `cmux` or `cmux-tui`
on `PATH`; then set `agents.memory.owner` as above. If the owner keeps `optchat-chief`
somewhere else, set `agents.memory.ownerCommand` to its argv.

## Agents cmux does not start

A terminal `claude` or `codex` (for example `sr codex` on a server) needs the entry in
its own config. Print it with the binary you will run:

```bash
optchat-chief agent-memory config codex
optchat-chief agent-memory config claude
```

The Codex entry pre-approves each tool (`approval_mode = "approve"`). Without that, a
session with `approval_policy = "never"` refuses the calls. The server answers
`initialize` and `tools/list` locally, without the owner, because Codex does not wait
for a slow server. Only tool calls go to the owner.

## From a shell

| Task | Command |
| --- | --- |
| Search (every word must match) | `optchat-chief agent-memory search WORDS` |
| Hits with source, date and full text | `optchat-chief agent-memory search --json WORDS` |
| One entry | `optchat-chief agent-memory get ID` |
| Save a lesson | `optchat-chief agent-memory remember TEXT` |
| This machine only | add `--local` |

Options go before the text. Everything after the first word of text is kept as
written, so `remember never pass --no-verify` saves all of it; `--` ends options early.

A note is refused, never redacted, when it is over 4000 characters, holds control
characters, or looks like a credential. The credential check is a backstop for common
token shapes, not a scanner. A memory file or note that matches it is left out of the
index; `agent-memory sync` and `agent-memory sources` name it so the secret can be
removed. Each note records its date, host, agent session and directory.

The index folder (`CMUX_AGENT_MEMORY_HOME`, default `~/.cmux/agent-memory`) is replaced
on each rebuild, so it must be new, empty, or an index already. A folder holding other
files is refused, never deleted, and so is a notes log (`CMUX_AGENT_MEMORY_NOTES`) inside
it.

## Migrating from `leo-workspace/tools/agent-memory`

The leo-workspace prototype (leo-workspace PRs #577 to #580) can retire. The index home
(`~/.cmux/agent-memory`) and the notes log (`~/.cmux/agent-memory-notes.jsonl`) keep
their paths, and old notes read as they are. The first search rebuilds the index in the
new format. Per machine:

1. Set `agents.memory.enabled` (and `owner` on machines other than the owner), plus
   `agents.memory.sources: ["~/Projects/leo-workspace/decisions"]` to keep those decisions.
2. Remove the hand-written `[mcp_servers.agent-memory]` from `~/.codex/config.toml`.
   Sessions cmux starts get the server; terminal Codex gets the output of
   `agent-memory config codex`.
3. Replace `--remote HOST` ssh aliases with `agents.memory.owner`. Remove the forced-command
   `agent-memory mcp` line from the owner's `~/.ssh/authorized_keys`, because the route
   uses the normal key.
4. Run the script and the new server on the same machine only briefly: each sees the
   other's manifest as stale and rebuilds.

## Evidence to report

`agent-memory sync` output on the owner, one relayed `agent-memory search` from each
connected machine with no fallback line, and the `cmux-agent-memory` server listed in
a new session's MCP tools.
