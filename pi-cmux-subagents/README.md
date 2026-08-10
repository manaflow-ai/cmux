# pi-cmux-subagents

`pi-cmux-subagents` launches Pi subagents as visible cmux workspaces. The first
child groups the parent workspace and its children under `Pi · <project>`.
Later children reuse that group and open without stealing focus.

It combines the useful conventions of
[`tintinweb/pi-subagents`](https://github.com/tintinweb/pi-subagents) and
[`nicobailon/pi-subagents`](https://github.com/nicobailon/pi-subagents) with a
cmux-native execution model:

- Claude Code-compatible `Agent`, `get_subagent_result`, and `steer_subagent` tools
- foreground and parallel background runs
- real interactive Pi sessions instead of hidden child processes
- collapsible cmux workspace grouping
- visible steering, session history, tool calls, and failures

## Install

From this repository:

```bash
pi install ./pi-cmux-subagents
```

After npm publication:

```bash
pi install npm:pi-cmux-subagents
```

The extension activates only when Pi runs inside cmux.

## Use

Ask naturally:

```text
Use an Explore subagent to map the authentication flow.
Run reviewer and Plan in parallel, visibly.
Have worker implement the approved change in a visible subagent.
```

The parent can call:

```ts
Agent({
  subagent_type: "Explore",
  prompt: "Find the authentication entry points and data flow.",
  description: "map auth",
  run_in_background: true
})
```

Supported types are `Explore`, `Plan`, `reviewer`, `worker`, and
`general-purpose`. Read-only roles receive only inspection tools. `worker`
receives file mutation tools.

Use `/cmux-agents` to show a compact status widget. Background completion is
delivered into the parent conversation automatically.

## How it works

1. The extension identifies the caller workspace through the cmux socket.
2. It reuses the caller's group, or creates `Pi · <project>` containing the parent.
3. It starts each child in an unfocused workspace directly after the parent.
4. A child-only `report_to_parent` tool atomically writes the final handoff.
5. The parent waits or watches that result and can steer the child through cmux.

Run data is stored under `~/.pi/agent/cmux-subagents/`.

## Requirements

- cmux with workspace-group CLI support
- Pi available as `pi` on `PATH`
- Pi launched from a cmux terminal

## Development

```bash
cd pi-cmux-subagents
npm install
npm test
npm run typecheck
```

## Acknowledgements

The tool naming, role model, and foreground/background ergonomics are inspired
by the MIT-licensed projects from
[tintinweb](https://github.com/tintinweb/pi-subagents) and
[Nico Bailon](https://github.com/nicobailon/pi-subagents). This package uses
an independent cmux-backed runtime.
