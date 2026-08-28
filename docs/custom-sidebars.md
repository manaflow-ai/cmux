# Custom sidebars: vibe-code your own cmux sidebar

cmux lets you build your own sidebar UI by writing a small SwiftUI-style file.
It is interpreted at runtime (no Xcode, no build step, no signing), renders as
native SwiftUI in the real sidebar, hot-reloads on save, binds to live cmux
state, and can run cmux commands on tap. This guide is the authoring contract
for you or a coding agent. It also covers HTML sidebars, which trade the live
bindings for the whole web platform.

This guide covers interpreted custom sidebars, which cannot import frameworks
or start child processes. For compiled Swift in an ExtensionKit sidebar, start
with the
[sample app](../Examples/SampleSidebarExtensionApp/README.md) and the
[CmuxExtensionKit authoring guide](../Packages/macOS/CmuxExtensionKit/README.md).
Compiled extensions run inside the macOS App Sandbox; if yours launches `git`
or another external tool, read
[Running external tools](../Packages/macOS/CmuxExtensionKit/README.md#running-external-tools)
before choosing an executable or opening a repository.

It is a beta, on by default. Turn it off in **Settings → Custom Sidebars**
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
- Iterate by saving the file and opening it as a pane with
  `cmux sidebar open <name>`; an interpreted sidebar hot-reloads there while you
  edit, and a web one refreshes on `cmux sidebar reload <name>`. Verify it shows
  real data and that taps do the right thing before declaring it done.
- Stay inside the supported subset below. If something is not supported, choose
  the closest supported approach rather than failing.

## Where to put a sidebar

Write a named file (the name becomes the menu label; use short kebab-case):

    ~/.config/cmux/sidebars/<name>.swift     # interpreted Swift (preferred)
    ~/.config/cmux/sidebars/<name>.json      # declarative JSON (simpler, static)
    ~/.config/cmux/sidebars/<name>.html      # a local HTML document
    ~/.config/cmux/sidebars/<name>.url       # a page served over http(s)

Each file shows up as an option in the **sidebar toggle button's right-click
menu** and can also open as a normal Bonsplit pane tab. Pick it from the menu
for the left sidebar, or run `cmux sidebar open <name>` to show it in a pane.
When one name has several files, the first of `.swift`, `.json`, `.html`, `.url`
wins, so adding an `.html` file never shadows an existing interpreted sidebar.

Interpreted sidebars (`.swift`, `.json`) hot-reload on save: edit the file, save,
and the sidebar re-renders. **Web sidebars do not.** `.html` and `.url` sidebars
refresh when you ask for it:

    cmux sidebar reload <name>     # this sidebar
    cmux sidebar reload            # all of them

That re-reads the file, re-resolves which file the name points at (so adding or
deleting a `.swift` beside your `.html` switches renderer), and for a `.url`
sidebar re-fetches from the server rather than the cache. Editing a page and
expecting the sidebar to notice on its own will not work — run the reload.

## HTML sidebars

`.swift` and `.json` sidebars describe a *render model* of rows and sections —
the right shape for a list of workspaces, but it cannot express an arbitrary
interface. When you want a real UI, or you already have a web app, use an HTML
sidebar: cmux renders the page in the sidebar with no browser chrome.

    ~/.config/cmux/sidebars/board.html                # rendered from disk

For an app you already serve, write a `.url` file containing its address. Plain
text or a Windows `[InternetShortcut]` file both work, so dragging a page out of
a browser produces a valid sidebar:

    printf 'http://127.0.0.1:8787/\n' > ~/.config/cmux/sidebars/board.url

Only `http` and `https` are honoured, and the address must name a host. A
`file://` target, a custom scheme, or a hostless string like `http:` is ignored
and the sidebar renders nothing, since a `.url` file is untrusted input that can
arrive by drag-and-drop.

A web sidebar refreshes on `cmux sidebar reload <name>`, not on save. See
[Where to put a sidebar](#where-to-put-a-sidebar).

The trade-off against an interpreted sidebar: the live data bindings above
(`workspaces`, `clock`, and the rest) and `cmux(...)` tap actions are features of
the interpreter, so an HTML sidebar does not get them. Read your data through
`cmux` on the CLI or its socket the way any other program does. In exchange you
get the whole web platform, including the interactive controls the interpreter
does not support (`TextField`, `@State`, popovers).

Focusing a workspace is the exception, and it has its own native call — see
below. Do not shell out to `cmux workspace select` for it from a sidebar that
qualifies; the native call is synchronous, tells you whether the workspace still
exists, and works across windows.

### Focusing a workspace from an HTML sidebar

A qualifying sidebar (see the next section) can select a workspace directly:

    const reply = await window.webkit.messageHandlers
        .cmuxSidebarFocusWorkspace
        .postMessage({ v: 1, workspaceId: id })

    // reply === { v: 1, status: 'focused' | 'not-found' | 'unavailable' }

The request must be exactly `{ v: 1, workspaceId: "<uuid>" }` — both keys, no
others, `v` the number `1`, and `workspaceId` a UUID string. Anything else
rejects the promise, including an extra key you might add for a later protocol
version. Handle the rejection; it is also what you get if the page has navigated
somewhere it is no longer allowed to call from.

The three statuses mean different things and are worth handling separately:

| `status` | Meaning | What to do |
| --- | --- | --- |
| `focused` | Selected, and its window was brought forward. | Nothing. |
| `not-found` | No workspace with that id. | Drop the row; your list is stale. |
| `unavailable` | No window could be resolved right now. | Transient — keep the row and let the user retry. |

Feature-detect rather than assuming: on a sidebar that does not qualify, and in a
Dock pane, the handler does not exist at all.

    const focus = window.webkit?.messageHandlers?.cmuxSidebarFocusWorkspace
    if (focus) {
      await focus.postMessage({ v: 1, workspaceId: id })
    } else {
      // Not a qualifying source. Fall back to the CLI, or render the rows
      // non-interactive rather than showing a button that silently does nothing.
    }

This is the only native call an HTML sidebar gets. There is no general command
bridge, and there is deliberately no way to pass a method name and parameters:
that would give any page the whole socket surface. Anything else still goes
through `cmux` on the CLI.

### Which sidebars can focus a workspace

The bridge is **workspace-rail only**. A sidebar opened as a Dock pane
(`cmux sidebar open <name>`) hosts the same page with no handler registered and
no navigation lock, whatever its source: a pane sits beside the terminals it
would be selecting, so there is nothing for it to bring forward. Feature-detect,
and the same page works in both places.

In the rail, only two kinds of source qualify, decided from the source alone
before the page loads:

- **`<name>.html`** — a local document in your sidebars directory.
- **`<name>.url`** pointing at a **literal loopback address**: `127.0.0.1`,
  anything else in `127.0.0.0/8`, or `[::1]`. Any port, `http` or `https`.

`http://localhost:8787/` does **not** qualify, and neither does any other
hostname. A name is whatever the resolver, the hosts file, or the network says it
is at that moment, so it cannot prove the server is on this machine. Use the
address literal: `http://127.0.0.1:8787/`. A public address never qualifies.

A qualifying sidebar is also **pinned to its own source** while it renders. A
local document may not navigate away from that file; a loopback page may not
leave its origin (same scheme, host, and port — paths and queries are free).
Redirects, cross-origin links, and `file:`-to-`http:` hops in the main frame are
cancelled rather than followed, which is what stops a page from carrying the
native call somewhere that never earned it. Iframes navigate freely, because the
lock applies to the main frame only. An iframe *can* post to the handler — the
handler is registered on the page, not on a frame — and the call is rejected at
dispatch: cmux checks that the message came from the main frame and that the
frame's origin still matches the armed source. So a subframe gets a rejected
promise, not a missing handler.

If you need to navigate the whole sidebar between origins, you are describing a
browser rather than a sidebar — use a Dock browser pane, or serve the pages from
one loopback origin and route inside it.

### Window chrome

The window's titlebar controls float over the top of the sidebar and the footer
floats over the bottom. By default cmux lays the page out inside the region they
leave free, so the page's viewport *is* the usable area and ordinary markup —
`height: 100vh` included — lands correctly. Write your page and ignore this.

If you want rows to scroll *underneath* the translucent chrome, the way the
built-in workspace list does, opt into the full sidebar rect and pad the content
yourself:

    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">

cmux then publishes the chrome heights as CSS custom properties on `:root`,
updated in place when the window changes:

    .toolbar { padding-top: var(--cmux-sidebar-inset-top); }
    .list    { padding-bottom: var(--cmux-sidebar-inset-bottom); }

These are custom properties rather than the usual `env(safe-area-inset-*)`
because macOS `WKWebView` does not forward the view's safe-area insets to CSS —
`env()` resolves to `0px` there regardless of what the host sets.

A sidebar file is a single SwiftUI-style view expression (no `struct`, no
`var body` wrapper, just the view).

## Choosing the renderer (in-process vs remote)

By default a custom sidebar renders in-process: the interpreted view mounts
as real SwiftUI inside the cmux window, so hover styling, focus, keyboard,
and same-frame resize all work natively. The tradeoff is that the
interpreter shares the host process.

For sidebars from sources you do not fully trust you can switch to the
remote renderer, an out-of-process worker. That is the containment lane: a
crash or hang caused by the interpreted file cannot take down cmux, but
input is limited to forwarded clicks (no hover, focus, or keyboard).

Set it in **Settings → Custom Sidebars**, or in `~/.config/cmux/cmux.json`:

    { "customSidebars": { "renderer": "remote" } }

Valid values are `"inProcess"` (default) and `"remote"`. The setting is read
live; flipping it re-renders the selected sidebar without a restart. Both
renderers protect the host against pathological sources with an evaluation
budget (nesting depth and total produced nodes): a render that exceeds the
budget is discarded and the last good render stays up.

## Downloadable examples

The repo includes ready-to-copy sidebars in `Examples/CustomSidebars/`:

- `status-board.swift` groups workspaces by live signals like urgent bugs,
  review, progress, research, and done.
- `finder.swift` shows a macOS Finder-style workspace browser with a source
  list, selected workspace details, and tabs.

Install one from a cmux checkout:

    mkdir -p ~/.config/cmux/sidebars
    cp Examples/CustomSidebars/status-board.swift ~/.config/cmux/sidebars/status-board.swift
    cp Examples/CustomSidebars/finder.swift ~/.config/cmux/sidebars/finder.swift

Then validate and open it as a Bonsplit pane:

    cmux sidebar validate status-board
    cmux sidebar open status-board

`cmux sidebar select <name>` still previews a custom sidebar in the left
sidebar picker. Use `cmux sidebar open <name>` when you want the sidebar as a
normal pane tab that can live in a right-side split.

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

Then right-click the sidebar button and choose **mine**, or open it as a pane
with:

    cmux sidebar open mine

## Live data you can bind to (read-only, refreshes ~1s)

- `workspaces` — array, one per workspace. Always present: `id`, `title`,
  `selected` (Bool), `pinned` (Bool), `index` (Int), `directory`, `ports`
  (array of Int) + `portCount`, `unread` (Int notifications), `tabs` + `tabCount`.
  Present when the workspace has them (use `if let` / ternary): `description`,
  `color` (hex), `branch` + `dirty` (Bool) from git, `pr`
  (`{ number, label, url, status: open|merged|closed, stale, branch }`, the
  workspace's first pull request in sidebar display order) + `prs` (array of
  the same shape with every pull request cmux knows for the workspace),
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
