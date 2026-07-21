# Floating Docks

A Floating Dock is a movable, resizable Bonsplit container owned by one workspace. It appears above that workspace's main content and hides when another workspace is selected. A workspace may own multiple Floating Docks.

New Floating Docks start with an autosaving note. Their tabs and panes use the same Bonsplit drag behavior as the existing right Dock, so terminals and browsers can move between the main workspace, right Dock, and Floating Docks without recreating the surface.

Create one from the command palette with `New Floating Dock`, or from the CLI:

```sh
cmux workspace float create --title Scratch --focus
cmux workspace float list --json
cmux workspace float note set float:1 "release checklist"
cmux workspace float pane create float:1 --type browser --direction right --url https://cmux.com
cmux workspace float hide float:1
```

`list --json` returns every Floating Dock in the target workspace, including its frame, presentation and focus state, panes, selected tabs, and surface identifiers. Mutations preserve the user's current focus unless `--focus` is explicit.

Run `cmux workspace float --help` for the complete command set. The target workspace defaults to the caller's `CMUX_WORKSPACE_ID`; use `--workspace <id|ref|index>` to inspect another workspace.

## Configuration

Project `.cmux/dock.json` can seed Floating Docks and the right Dock from one schema. The top-level `controls` array remains the backwards-compatible right-Dock schema; the optional top-level `floats` array declares workspace floats:

```json
{
  "controls": [
    { "id": "git", "title": "Git", "command": "lazygit" }
  ],
  "floats": [
    {
      "id": "scratch",
      "title": "Scratch",
      "frame": { "x": 36, "y": 80, "width": 520, "height": 380 },
      "content": { "id": "note", "title": "Notes", "type": "note" }
    },
    {
      "id": "preview",
      "title": "Preview",
      "frame": { "width": 640, "height": 480 },
      "content": {
        "id": "browser",
        "title": "App",
        "type": "browser",
        "url": "http://localhost:3000"
      }
    }
  ]
}
```

`content` reuses the Dock control schema: omit `type` for a terminal with `command`, use `browser` with `url`, or use `note`. Omitting `content` creates the normal autosaving note. Missing frame values use a cascaded origin and a `520` × `380` size; minimum size is `320` × `220`.

Config seeds only the initial state. Identity is the resolved project config source plus the float's config `id`, persisted with the workspace session. The config `id` is separate from runtime UUIDs and `float:N` CLI selectors. A matching restored float is not duplicated or overwritten; saved title, frame, and visibility win. Closing a seeded float keeps it closed after restart. Adding a new ID seeds only the new entry, while editing or removing an old ID does not reconcile the existing float.

Global `~/.config/cmux/dock.json` does not support `floats` in this version because floats belong to a project workspace. A non-empty global `floats` array produces **Dock Config Error** rather than being ignored. Unknown keys and malformed sections use the same error path.

See [Dock](dock.md) for the complete unified schema, trust behavior, config precedence, and the backwards-compatibility guarantee.
