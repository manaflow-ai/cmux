# Custom sidebars: vibe-code your own cmux sidebar

cmux lets you build your own sidebar UI by writing a small SwiftUI-style file.
It is interpreted at runtime (no Xcode, no build step, no signing), renders as
native SwiftUI in the real sidebar, hot-reloads on save, binds to live cmux
state, and can run cmux commands on tap. This guide is the authoring contract
for you or a coding agent.

It is an opt-in beta: turn on **Settings → Beta features → Custom sidebars**
(`customSidebars.beta.enabled`). While off, custom sidebars do not appear.

## If you are an agent building this for someone

Assume the person asking is not technical. They are describing a result ("a
sidebar that shows my workspaces and lets me jump between them"), not an
implementation. Your job is to turn that into a clean, native-looking, working
sidebar and make the engineering decisions for them. Do not ask them about
SwiftUI, files, or syntax. Concretely:

- Default to real, live data. If they mention workspaces/tabs, bind to the
  `workspaces` context (not hard-coded text) so it stays correct on its own.
- Make it interactive by default. Rows that represent something you can open
  should be tappable and run the matching `cmux(...)` action (e.g. selecting a
  workspace, focusing a tab). A list that just displays text is rarely what
  they wanted.
- If the list is something a person would naturally reorder (workspaces, tasks,
  a queue), make it drag-and-drop reorderable with `Reorderable` (see below).
  When in doubt for a workspace list, prefer `Reorderable`.
- Keep it native and uncluttered: a title, a divider, then the content. Use the
  status dot / pill / highlight patterns below so it is scannable at a glance.
- Lazy-load / cap large lists (see Performance). Do not render hundreds of rows.
- Iterate by saving the file and looking at the result (it hot-reloads); fix
  what looks off. Verify it shows real data and that taps do the right thing
  before declaring it done.
- Stay inside the supported subset below. If something is not supported, choose
  the closest supported approach rather than failing.

## Where to put a sidebar

Write a named file (the name becomes the menu label; use short kebab-case):

    ~/.config/cmux/sidebars/<name>.swift     # interpreted Swift (preferred)
    ~/.config/cmux/sidebars/<name>.json      # declarative JSON (simpler, static)

Each file shows up as an option in the **sidebar toggle button's right-click
menu**. Pick it and it renders in the sidebar; edit the file and save and it
hot-reloads. If both `<name>.swift` and `<name>.json` exist, `.swift` wins.

A sidebar file is a single SwiftUI-style view expression (no `struct`, no
`var body` wrapper, just the view).

## Quick start

    cat > ~/.config/cmux/sidebars/mine.swift <<'SWIFT'
    VStack(alignment: .leading, spacing: 8) {
        Text("My sidebar").font(.title3).bold()
        Text(clock.time).font(.caption).foregroundColor(.secondary)
        Divider()
        ForEach(workspaces) { w in
            Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
                HStack {
                    Text(w.selected ? "●" : "○").foregroundColor(w.selected ? "#FF8800" : .secondary)
                    Text(w.title)
                    Spacer()
                }
            }
        }
    }
    SWIFT

Then right-click the sidebar button and choose **mine**.

## Live data you can bind to (read-only, refreshes ~1s)

- `workspaces` — array, one per workspace. Always present: `id`, `title`,
  `selected` (Bool), `pinned` (Bool), `index` (Int), `directory`, `ports`
  (array of Int) + `portCount`, `unread` (Int notifications), `tabs` + `tabCount`.
  Present when the workspace has them (use `if let` / ternary): `description`,
  `color` (hex), `branch` + `dirty` (Bool) from git, `pr`
  (`{ number, label, url, status: open|merged|closed, stale, branch }`),
  `progress` (`{ value: 0..1, label }`), `latestMessage` (last agent message),
  `latestPrompt` (last submitted prompt), `latestAt` (epoch), `remote`
  (`{ target, state, connected }`).
- `tabs` (per workspace) — array of surfaces. Always: `id`, `title`,
  `focused` (Bool), `pinned` (Bool). When available: `directory`, `branch` +
  `dirty`, `ports` (array of Int).
- `workspaceCount` — Int. `selectedTitle` — active workspace's title.
  `selectedId` — its id. `unreadTotal` — total unread notifications.
- `clock` — `{ time ("HH:mm:ss"), hour, minute, second, weekday, epoch }`. The
  sidebar re-renders about once a second, so clocks/countdowns and workspace
  changes are live.

Optional fields are omitted when the workspace doesn't have them, so guard with
`if let b = w.branch { ... }` or `w.pr != nil ? ... : ...` rather than assuming
they exist.

## Views

Containers: `VStack(alignment:spacing:)`, `HStack`, `ZStack`, `LazyVStack`,
`LazyHStack`, `Group`, `EmptyView()`, `List { ... }`, `Section("Header") { ... }`,
`Grid { GridRow { ... } }`, `LazyVGrid`, `LazyHGrid`, `ViewThatFits { ... }`,
`ScrollView { ... }` (use `ScrollView(.horizontal) { HStack { ... } }` for a
horizontal strip — vertical scrolling is automatic), and
`HSplitView { columnA; columnB }` (two resizable, independently-scrolling
columns with a persisted divider).

Content: `Text("...")`, `Label("Title", systemImage: "folder")`,
`Image(systemName: "folder.fill")` (SF Symbols),
`Button("Title") { <action> }` / `Button(action:){ <label> }`,
`Menu("Title") { <items> }`, `ProgressView(value: 0.4)` / `ProgressView()`,
`Gauge(value: 0.7)`, `Spacer()`, `Divider()`, `AnyView(<view>)`.

Shapes: `Rectangle`, `RoundedRectangle(cornerRadius:)`,
`UnevenRoundedRectangle`, `Capsule`, `Circle`, `Ellipse` — fill with
`.fill(color)` / `.foregroundColor`, outline with `.stroke("#hex", lineWidth: 2)`,
arc with `.trim(from:to:)`, size with `.frame`.

Reorder: `Reorderable(data, move: "workspace.reorder") { item in <row> }` (see below).

## Modifiers

Text/typography: `.font(.title2|.headline|.caption|.system(size:design:)...)`,
`.bold()`, `.italic()`, `.fontWeight(.semibold)`, `.fontDesign(.monospaced)`,
`.monospaced()`, `.monospacedDigit()`, `.lineLimit(1)`, `.truncationMode(.tail)`,
`.multilineTextAlignment(.center)`, `.textCase(.uppercase)`, `.strikethrough()`,
`.underline()`.

Color/fill: `.foregroundColor`/`.foregroundStyle`/`.fill`/`.tint` taking a hex
string `"#FF8800"` or a token (`primary`, `secondary`, `tertiary`, `accent`,
`red`, `blue`, `mint`, `indigo`, `teal`, `cyan`, `brown`, …). `Color("#hex")` /
`Color(red:green:blue:)` values too.

Layout: `.padding(8)`, `.frame(width:height:maxWidth:.infinity, alignment:)`,
`.fixedSize()`, `.layoutPriority(1)`, `.offset(x:y:)`, `.zIndex(1)`,
`.aspectRatio(contentMode:.fit)`, `.scaledToFit()`/`.scaledToFill()`.

Decoration: `.background("#hex")` **or** `.background { <view> }`,
`.overlay(alignment:.topTrailing) { <view> }`, `.mask { <view> }`,
`.safeAreaInset(edge:.top) { <view> }`, `.cornerRadius(8)`,
`.clipShape(Circle())`, `.clipped()`, `.shadow(color:radius:x:y:)`,
`.border(.gray, width:1)`, `.blur(radius:)`, `.opacity(0.6)`,
`.brightness`/`.contrast`/`.saturation`/`.grayscale`,
`.rotationEffect(.degrees(45))`, `.scaleEffect(1.2)`, `.redacted(reason:.placeholder)`.

SF Symbols: `.imageScale(.large)`, `.symbolRenderingMode(.hierarchical)`,
`.symbolVariant(.fill)`.

Interaction/semantics: `.onTapGesture { <action> }` (any view tappable),
`.contextMenu { <buttons> }`, `.help("tip")`, `.disabled(cond)`,
`.accessibilityLabel("...")`.

The decoration modifiers that take a trailing `{ <view> }` (`.overlay`,
`.background`, `.mask`, `.safeAreaInset`, `.contextMenu`) accept **any** nested
view, so you can compose badges, rings, status dots, etc.

## Language

`let` bindings; user `func` helpers (value helpers and view helpers returning
`some View`, explicit `return` supported); `for i in 0..<n` / `1...n` /
`for x in array`; `ForEach(array) { item in ... }`,
`ForEach(array.indices) { i in }`, and
`ForEach(Array(array.enumerated()), id: \.offset) { i, item in }`; `if/else`;
ternary `cond ? a : b` (works in modifiers and interpolation); string
interpolation `"\(expr)"`; arithmetic `+ - * / %` (safe on `/ 0`); comparisons;
`&& || !` (short-circuiting); ranges; array/dictionary literals; member access
(`obj.field`, `array.count`/`.first`/`.last`/`.indices`, `string.count`);
subscript `array[i]`, `obj["key"]`.

Array methods: `.filter`, `.map`, `.flatMap`, `.reduce`, `.sorted { $0 > $1 }`,
`.first`, `.contains`, `.count`, `.reversed`, `.prefix(n)`, `.suffix(n)`,
`.dropFirst(n)`, `.dropLast(n)`, `.enumerated()`, `.indices`. String methods:
`.hasPrefix`, `.hasSuffix`, `.contains`, `.uppercased()`, `.lowercased()`,
`.split(separator:)`. Numbers: `.formatted(.currency(code:"USD"))` /
`.formatted(.percent)` / `.formatted(.notation(.compactName))`. Builtins:
`min`, `max`, `abs`, `Int(...)`, `Double(...)`, `String(...)`.

## Actions (run real cmux commands on tap)

A button or `.onTapGesture` body calls `cmux("<method>", param: value)`. On tap
it runs that cmux command through the same dispatcher as the `cmux` CLI:

    Button(action: { cmux("workspace.select", workspace_id: w.id) }) { ... }
    ...onTapGesture { cmux("surface.focus", surface_id: t.id) }

Use real method and parameter names. Common ones: `workspace.select`
(`workspace_id`), `surface.focus` (`surface_id`), `workspace.reorder`
(`workspace_id` + `index`). Run `cmux docs api` to discover the full command
surface.

## Drag-and-drop reordering (persisted)

Drag-and-drop is achieved with `Reorderable`. This is the supported way to make
a list draggable, do not reach for `List`/`.onMove`/`.draggable` directly. Wrap
rows in `Reorderable`; the rows become draggable and dropping one onto another
runs the `move` command, which both reorders and persists (cmux remembers
workspace order):

    Reorderable(workspaces, move: "workspace.reorder") { w in
        Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
            HStack { Text(w.title); Spacer() }.padding(6)
        }
    }

The dropped item's id and target index are sent as `workspace_id` and `index`.

## Two-column (Finder-style) example

    HSplitView {
        VStack(alignment: .leading) {
            for i in 0..<workspaces.count {
                Button(action: { cmux("workspace.select", workspace_id: workspaces[i].id) }) {
                    HStack { Image(systemName: "folder.fill"); Text(workspaces[i].title); Spacer() }.padding(4)
                }
            }
        }
        VStack(alignment: .leading) {
            for i in 0..<workspaces.count {
                if workspaces[i].selected {
                    for j in 0..<workspaces[i].tabs.count {
                        Button(action: { cmux("surface.focus", surface_id: workspaces[i].tabs[j].id) }) {
                            HStack { Image(systemName: "doc.text"); Text(workspaces[i].tabs[j].title); Spacer() }.padding(4)
                        }
                    }
                }
            }
        }
    }

## Not yet supported

The interpreter is a growing subset. `.overlay`/`.background`/`.mask`/
`.contextMenu` with arbitrary nested views, `Menu`, `List`/`Section`/grids,
shape `.stroke`/`.trim`, and user `func` helpers are all supported now.

Still missing: `@State` and the interactive input controls that need it
(`TextField`, `Toggle`, `Slider`, `Picker`) — buttons/taps that run `cmux(...)`
work, but two-way-bound editing does not yet; `switch`; custom `struct`/`View`
definitions; `gradients` (`LinearGradient`/…); navigation (`sheet`/`popover`/
`NavigationStack`); `.keyboardShortcut`; `AsyncImage`/`.resizable`. Workspace
data (git branch/dirty, ports, PR, unread, remote, latest agent/prompt messages)
is live; data cmux doesn't track (custom domain collections) won't appear.

If your sidebar needs a missing feature, write it the natural Swift way anyway —
unsupported syntax is skipped (and even deeply nested or pathological source is
rendered best-effort, never crashes) — and ask for the feature.

## Performance and lazy loading

The sidebar re-evaluates roughly once a second (so clocks and data stay live),
and it renders rows eagerly. Keep each render cheap and the list bounded:

- Cap long lists. Show what fits and slice the rest: `for w in workspaces.prefix(20) { ... }`
  or `ForEach(items.prefix(50)) { ... }`. Do not render hundreds of rows.
- Filter/sort to what matters before rendering (`workspaces.filter { ... }`,
  `.sorted()`) rather than rendering everything and hiding most of it.
- Only render detail for the selected item. In a two-column layout, build the
  right column from the selected workspace's tabs, not every workspace's tabs.
- Prefer one focused sidebar over a giant catch-all; deep nesting and huge
  trees cost the most per tick.

## Tips

- Prefer `ForEach`/`Reorderable` over index loops where you can.
- Errors show inline in the sidebar with the failing location; fix and save.
- Keep modifier arguments simple literals or tokens.
- The JSON form is good for static layouts; use Swift for anything dynamic.
