---
name: cmux-harness
description: "Add a coding agent (harness) to cmux: write, check and share a harness manifest so the agent appears in cmux's picker and New Tab. Use when asked to add, integrate or support an agent, CLI or internal company harness in cmux, or to fix one that does not show up."
---

# Add a harness to cmux

cmux drives agents over the Agent Client Protocol (ACP). Any agent with an ACP
mode on stdio becomes a cmux harness through a folder with `harness.json` and an
icon. No cmux code changes and no rebuilds; a running cmux picks it up on save.
The full field reference is `cmux-tui/crates/acpmux/docs/harness-manifests.md`.

## Steps

1. Find how the agent speaks ACP. Read its `--help` and docs for `acp`,
   `--acp`, `--experimental-acp` or "Agent Client Protocol". If it has no ACP
   mode, look for an ACP adapter package (`<agent>-acp`); without one, stop and
   say so, because cmux cannot drive it.
2. Find its sign-in commands (`login`, `auth`, `setup`) and any "am I signed
   in" command that exits 0.
3. Scaffold: `cmux harness add <id>`. This creates
   `~/.config/cmux/harnesses/<id>/harness.json` and a placeholder `icon.svg`.
   The id is lowercase letters, digits and dashes.
4. Fill in `harness.json`:
   - `run.command`: the program, which must be on the login PATH or an
     absolute path. `run.args`: the arguments that start ACP on stdio.
     `run.install`: the install command.
   - `auth.logins`: one entry per sign-in method (`{id, label, args}`); cmux
     runs `command args` in a terminal tab.
   - `models.source`: `acp` when the agent reports its models. Otherwise
     `static`, with `models.list` filled in.
   - `capabilities`: the ACP config option ids for `fast` and `effort` if the
     agent has them; `permissions: true` if it asks before running tools;
     `resume: true` if `session/load` works.
5. Icon: a single-color SVG drawn with `fill="currentColor"` (or `stroke`), so
   it follows light and dark themes. Use paths only: no scripts, `<image>`,
   `<use>`, `<foreignObject>` or outside URLs. Take the mark from the agent's
   site or repo when it has one.
6. `cmux harness check <id>` must print `ok`. Fix each `field: message` it
   reports. A warning that the command is missing means it isn't installed
   on this machine yet; the manifest is still valid.
7. Try it: `cmux acp new -m <id> "say hi"` (or pick it in New Tab). If it
   fails, run the command and args by hand. An ACP server waits silently for
   JSON-RPC on stdin, while a TUI or an error means the args are wrong.

## Share it with a team

Commit the folder to the company's repo as `.cmux/harnesses/<id>/`. Teammates
run `cmux harness add --from <git url>`, and cmux offers it to anyone working
in that repo. Only `harness.json` and the icon are installed, after the check
passes; nothing else in the repo runs.

For a repo's AGENTS.md:

```md
## cmux
Our agent is a cmux harness in `.cmux/harnesses/<id>/`. Install it with
`cmux harness add --from <this repo's git url>`; after editing it, run
`cmux harness check <id>`.
```

## Don'ts

- Don't put API keys or tokens in `run.env`. Sign-ins belong to the agent's
  own login.
- Don't edit `~/.acpmux/config.json` to add a harness; that file overrides
  manifests and is meant for local tweaks.
- Don't pick an id cmux already ships (`fx`) or one found on PATH (`codex`,
  `claude`, `opencode`, `gemini`, `pi`) unless you mean to replace it.
