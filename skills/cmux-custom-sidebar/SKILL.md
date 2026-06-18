---
name: cmux-custom-sidebar
description: "Build a custom cmux sidebar from a plain-language request. Use when the user asks for a custom sidebar, a sidebar that shows their workspaces/tabs/PRs/clock, a vibe-coded sidebar, or anything involving files in ~/.config/cmux/sidebars/. Covers authoring the interpreted SwiftUI-style file, enabling the beta flag, selecting it, and iterating with hot reload."
---

# cmux Custom Sidebar

cmux renders custom sidebars from a small SwiftUI-style file at runtime: no Xcode, no build step, no signing. The file hot-reloads on save, binds to live cmux state (workspaces, tabs, git, PRs, clock), and can run real cmux commands on tap.

The person asking is usually describing a result ("a sidebar that shows my workspaces and lets me jump between them"), not an implementation. Turn that into a clean, native-looking sidebar and make the engineering decisions for them. Do not ask them about SwiftUI, files, or syntax.

## Full reference

This skill is the workflow summary. The complete authoring contract (every supported view, modifier, language feature, and data field) is one command away; read it before writing a non-trivial sidebar:

```bash
cmux docs sidebars
curl -fsSL https://raw.githubusercontent.com/manaflow-ai/cmux/main/docs/custom-sidebars.md
```

## Workflow

1. **Enable the beta** (once). Custom sidebars are behind Settings → Beta features → Custom sidebars (`customSidebars.beta.enabled`). If a written sidebar does not appear in the picker, this flag is the first thing to check.
2. **Write a named file.** The name becomes the menu label; use short kebab-case:
   ```
   ~/.config/cmux/sidebars/<name>.swift
   ```
   The file is a single SwiftUI-style view expression (no `struct`, no `var body`, no imports). A `.json` variant exists for static layouts; prefer `.swift` for anything dynamic.
3. **Validate and select it:**
   ```bash
   cmux sidebar validate <name>   # parse/interpret check with real data shapes
   cmux sidebar select <name>     # switch the sidebar to it
   ```
   The user can also pick it manually: right-click the sidebar toggle button.
4. **Iterate.** Saving the file hot-reloads the sidebar in place (`cmux sidebar reload` forces it). Look at the result, fix what looks off, and verify rows show real data and taps do the right thing before declaring it done.

## Authoring rules

- **Default to live data.** Bind to the `workspaces` context instead of hard-coding text so the sidebar stays correct on its own.
- **Make it interactive by default.** Rows that represent something openable should run the matching `cmux(...)` action on tap. A list that just displays text is rarely what they wanted.
- **Prefer `Reorderable` for workspace-like lists.** It gives persisted drag-and-drop reordering for free.
- **Keep it native and uncluttered:** a title, a divider, then the content.
- **Cap long lists** (`.prefix(20)`, filter/sort before rendering). The sidebar re-evaluates about once a second; do not render hundreds of rows.
- **Stay inside the supported subset.** Unsupported syntax is skipped gracefully (never crashes), but choose the closest supported approach rather than shipping a half-blank sidebar.

## Quick start

```bash
cat > ~/.config/cmux/sidebars/mine.swift <<'SWIFT'
VStack(alignment: .leading, spacing: 8) {
    Text("My sidebar").font(.title3).bold()
    Text(clock.time).font(.caption).foregroundColor(.secondary)
    Divider()
    Reorderable(workspaces, move: "workspace.reorder") { w in
        Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
            HStack {
                Text(w.selected ? "●" : "○").foregroundColor(w.selected ? "#FF8800" : .secondary)
                Text(w.title)
                Spacer()
            }.padding(4)
        }
    }
}
SWIFT
cmux sidebar validate mine && cmux sidebar select mine
```

## Live data context (read-only, refreshes ~1s)

- `workspaces`: array with `id`, `title`, `selected`, `pinned`, `index`, `directory`, `ports` + `portCount`, `unread`, `tabs` + `tabCount`; plus, when present: `description`, `color`, `branch` + `dirty`, `pr` / `prs` (`{number, label, url, status, stale, branch}`), `progress` (`{value, label}`), `latestMessage`, `latestPrompt`, `latestAt`, `remote` (`{target, state, connected}`).
- `workspaces[i].tabs`: `id`, `title`, `focused`, `pinned`; plus `directory`, `branch` + `dirty`, `ports` when available.
- `clock`: `{time, hour, minute, second, weekday, epoch}`.
- Scalars: `workspaceCount`, `selectedTitle`, `selectedId`, `unreadTotal`.

Optional fields are omitted when absent; guard with `if let b = w.branch { ... }` or `w.pr != nil ? ... : ...`.

## Actions

A button or `.onTapGesture` body calls `cmux("<method>", param: value)`, dispatched through the same surface as the `cmux` CLI. Common methods: `workspace.select` (`workspace_id`), `surface.focus` (`surface_id`), `workspace.reorder` (`workspace_id` + `index`). `openURL("https://...")` opens links. Discover the full command surface with `cmux docs api`.

## Supported subset at a glance

Containers: stacks (incl. lazy), `Group`, `List`, `Section`, grids, `ViewThatFits`, `ScrollView`, `HSplitView` (two resizable columns). Content: `Text`, `Label`, `Image(systemName:)`, `Button` (title and label form), `Menu`, `ProgressView`, `Gauge`, `Spacer`, `Divider`, shapes, gradients via `.background`. Modifiers: full typography set, colors as hex strings or tokens, `.padding`/`.frame`/layout, `.background`/`.overlay`/`.mask`/`.contextMenu` with arbitrary nested views, shadows/borders/opacity/effects, `.onTapGesture`, `.help`, `.disabled`. Language: `let`, user `func` helpers, `for`/`ForEach`, `if/else`, ternary, string interpolation, arithmetic, array methods (`filter`/`map`/`sorted`/`prefix`/...), string and number formatting.

Not yet supported (write the natural Swift anyway; it degrades gracefully): `@State` and input controls (`TextField`, `Toggle`, `Slider`, `Picker`), custom `struct`/`View` definitions, navigation (`sheet`/`popover`), `AsyncImage`. Two-way editing does not work yet; taps that run `cmux(...)` do.

## Troubleshooting

- Sidebar missing from the right-click picker: the beta flag is off, or the file is not directly under `~/.config/cmux/sidebars/`.
- Blank or partial render: run `cmux sidebar validate <name>`; errors show inline in the sidebar with the failing location. A broken save keeps the last working render on screen, so re-save after fixing.
- Rows not tappable: wrap the row in `Button(action: { cmux(...) }) { ... }` or add `.onTapGesture { cmux(...) }`.
- Reorder not persisting: use `Reorderable(data, move: "workspace.reorder")`, not `List`/`.onMove`/`.draggable`.
