# Local app views

A complete example for the request "a view of the PRs from the last 24h". It
writes the customize app (`~/.config/cmux/customize`, id `local/customize`): a
sidebar section in the band under the workspace list, and a Session Info section
that lists the chat branch's pull requests. cmux watches the folder: each save
reloads the app, and the first save installs it. There is no restart and no
install click.

`cmux-tui/crates/cmux-app-manifest/tests/customize_example.rs` validates the two
files below as written. The daemon reads manifest v2 only. One app implements
each interface once, so
the customize app has at most one sidebar section (`cmux.section/1`) and one
Session Info section (`cmux.session.info.section/1`).

## The manifest

`~/.config/cmux/customize/cmux-app.json`:

```json
{
  "$schema": "https://cmux.dev/schemas/cmux-app/2.json",
  "manifestVersion": 2,
  "id": "local/customize",
  "name": "My views",
  "version": "1.0.0",
  "description": "Pull requests from the last 24 hours, and the chat branch's pull requests.",
  "engines": { "cmux": "^2.0" },
  "runtime": { "main": "main.js" },
  "implements": {
    "cmux.section/1": {
      "export": "renderRecent",
      "title": "PRs · last 24h",
      "symbol": "clock.arrow.circlepath",
      "options": { "defaultRegion": "bottom", "maxRows": 10 }
    },
    "cmux.session.info.section/1": {
      "export": "renderBranch",
      "title": "Branch pull requests",
      "symbol": "arrow.triangle.pull",
      "options": { "maxRows": 8 }
    }
  },
  "scopes": {
    "integration:github:read": "Read pull requests with the connected GitHub account.",
    "actions:run": "Open a pull request when you click its row."
  }
}
```

### Scopes

A customize app is an unverified local app. At install it gets the read scopes
it asks for under `scopes`, so `integration:github:read` works at once once
GitHub is connected in cmux. Any other scope (`actions:run`, `net:<host>`) stays
off until the person turns it on in Settings > Apps > My views. Until then a
row shows its URL on hover, and a click does nothing. An agent cannot grant a
scope; tell the person which one to turn on and why.

## The script

`~/.config/cmux/customize/main.js` is a plain classic script, not a module: no
`import` or `export`. The scene globals (`VStack`, `Row`, `ForEach`,
`EmptyState`, `signal`, `computed`, `cmux`, ...) are already defined, and the
script hands its render functions to cmux through `globalThis.__cmuxAppExports`.
A render function gets the mount context as its argument; a Session Info
section's is `{ session_id, cwd, branch?, harness? }`.

```js
const repoOf = (url) => String(url || "").replace("https://api.github.com/repos/", "")

async function search(query) {
  const r = await cmux.integrations.github.request({ method: "GET", path: `/search/issues?q=${encodeURIComponent(query)}&per_page=50` })
  return r.items
}

const toRow = (i) => ({ id: i.id, number: i.number, title: i.title, url: i.html_url, repo: repoOf(i.repository_url), open: i.state === "open", merged: !!(i.pull_request && i.pull_request.merged_at), updated: i.updated_at })

const prList = (rows, error, empty) =>
  VStack({ spacing: 2 }, [
    ForEach({ items: computed(() => rows() || []), key: (p) => p.id }, (p) =>
      Row({
        title: () => p().title,
        subtitle: () => `${p().repo} #${p().number}${p().merged ? " · Merged" : p().open ? "" : " · Closed"}`,
        symbol: () => (p().merged ? "checkmark.circle" : "arrow.triangle.pull"),
        tint: () => (p().merged ? "accent" : p().open ? "success" : "secondary")
      })
        .help(() => p().url)
        .onTap(() => cmux.actions.run("openBrowser", { url: p().url }))
    ),
    () => (error() ? EmptyState({ title: "Cannot load pull requests", message: error(), symbol: "exclamationmark.triangle" }) : null),
    () => (!error() && rows() && rows().length === 0 ? EmptyState({ title: empty, symbol: "checkmark.circle" }) : null)
  ])

// PRs created or updated in the last 24 hours that involve you (author, review requested,
// assignee), open and merged, newest first. Search has no OR across these, so three searches.
function renderRecent() {
  const [rows, setRows] = signal(null)
  const [error, setError] = signal(null)
  const load = async () => {
    const since = new Date(Date.now() - 24 * 60 * 60000).toISOString().slice(0, 19) + "Z"
    try {
      const batches = await Promise.all(["author", "review-requested", "assignee"].map((role) => search(`is:pr ${role}:@me updated:>=${since}`)))
      const byId = new Map()
      for (const row of batches.flat().map(toRow)) if (row.open || row.merged) byId.set(row.id, row)
      setRows([...byId.values()].sort((a, b) => b.updated.localeCompare(a.updated)))
      setError(null)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }
  load()
  cmux.timer.every(5 * 60000, load)
  return prList(rows, error, "No pull requests in the last 24 hours")
}

// The chat's branch, searched across GitHub (a script cannot read the git remote).
function renderBranch(context) {
  const branch = String((context && context.branch) || "").trim()
  if (!branch) return EmptyState({ title: "No branch for this chat", symbol: "arrow.triangle.branch" })
  const [rows, setRows] = signal(null)
  const [error, setError] = signal(null)
  const load = async () => {
    try {
      setRows((await search(`is:pr head:${branch}`)).map(toRow))
      setError(null)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }
  load()
  cmux.timer.every(5 * 60000, load)
  return prList(rows, error, `No pull requests for ${branch}`)
}

globalThis.__cmuxAppExports = { renderRecent, renderBranch }
```

## Matching the app

A pane looks like cmux when it is built only from the kit, which the app draws
with its own controls, surfaces, fonts and spacing and redraws when the theme
changes. Nothing in the script picks a color or a size.

| Piece | Use it for |
|---|---|
| `Panel({ title?, style? }, [...])` | A group on the app's card surface, with its padding and radius. `style: "glass"` (default) is the sidebar cards' glass; `"card"` is opaque. |
| `Row({ title, subtitle?, symbol?, badge?, tint?, accessory? })` | A list row, the same as the sidebar's own rows (hover, selection, `.onTap`). |
| `Button(title, fn)`, `Menu(title, [Button(...), Divider()])` | Actions and a pull-down menu. |
| `Toggle(value, { label?, onChange })` | A switch row: the label leading, the native switch trailing. |
| `Slider(value, { min, max, step, onChange })` | A native slider; set `step` so a drag sends few changes. |
| `TextField(value, { placeholder, onSubmit })`, `Badge`, `EmptyState`, `ProgressView`, `Text`, `Icon` | Input, counts, empty and loading states, labels, SF Symbols. |
| `cmux.toast({ title, message?, tone? })` | A short notice in the app's own toast at the bottom of the window. One slot per app: a new toast replaces the app's last. The message shows when the pointer is on it, with the app's id. Needs no scope. |
| `cmux.theme` | The tone names color props accept: `accent`, `text.primary`, `text.secondary`, `text.tertiary`, `success`, `warning`, `danger`, `separator`, `hover`, `selected`. |

Rules:

- No literal colors: pass a tone (`tint: cmux.theme.success`, `.color("secondary")`),
  never `#RRGGBB`. A hex color stays the same in every theme, and the app's
  colors do not.
- No literal sizes: fonts by name (`.font("headline")`, `"caption"`), no point
  sizes, no `.padding(13)` or `.cornerRadius(9)` on pieces the kit already
  spaces. Put groups in a `Panel` instead of drawing a background.
- `Toggle` and `Slider` are two-way: keep the value in a `signal`, pass the
  signal, and set it in `onChange`.

### Template: a focus timer

A sidebar pane built only from the kit: a `Panel` with the time, a `Slider`
for the length, a `Toggle`, a `Button` and a `Menu` of presets, a `Row` with
today's count, and a toast when a session starts and ends. It needs no scopes.
Copy both files as written, or use them as the starting point for "make me a
pane that ...". `customize_example.rs` validates them too.

#### Focus timer manifest

`~/.config/cmux/customize/cmux-app.json`:

```json
{
  "$schema": "https://cmux.dev/schemas/cmux-app/2.json",
  "manifestVersion": 2,
  "id": "local/customize",
  "name": "My views",
  "version": "1.0.0",
  "description": "A focus timer in the sidebar.",
  "engines": { "cmux": "^2.0" },
  "runtime": { "main": "main.js" },
  "implements": {
    "cmux.section/1": {
      "export": "renderFocus",
      "title": "Focus timer",
      "symbol": "timer",
      "options": { "defaultRegion": "bottom" }
    }
  }
}
```

#### Focus timer script

`~/.config/cmux/customize/main.js`:

```js
const [minutes, setMinutes] = signal(25)
const [left, setLeft] = signal(null) // seconds left while a session runs, else null
const [total, setTotal] = signal(0) // the running session's length in seconds
const [notify, setNotify] = signal(true)
const [done, setDone] = signal(0)
const running = computed(() => left() !== null) // the slots below rebuild on start and stop, not every second
let tick = null

const clock = (s) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`

function stop(finished) {
  if (tick !== null) cmux.timer.clear(tick)
  tick = null
  setLeft(null)
  if (finished) {
    setDone((n) => n + 1)
    if (notify()) cmux.toast({ title: "Focus session done", message: "Take a short break.", tone: "success" })
  }
}

function start() {
  stop(false)
  setTotal(minutes() * 60)
  setLeft(total())
  tick = cmux.timer.every(1000, () => {
    const next = (left() ?? 0) - 1
    if (next <= 0) stop(true)
    else setLeft(next)
  })
  cmux.toast({ title: `Focus for ${minutes()} minutes` })
}

function renderFocus() {
  return VStack([
    Panel({ title: "Focus" }, [
      Text(() => clock(left() ?? minutes() * 60)).font("headline").monospaced(),
      () => (!running()
        ? Slider(minutes, { min: 5, max: 60, step: 5, onChange: setMinutes })
        : ProgressView(() => 1 - (left() ?? 0) / total())),
      Toggle(notify, { label: "Toast when done", onChange: setNotify }),
      HStack([
        () => (!running() ? Button("Start", start) : Button("Stop", () => stop(false))),
        Spacer(),
        Menu("Presets", [Button("15 minutes", () => setMinutes(15)), Button("25 minutes", () => setMinutes(25)), Button("50 minutes", () => setMinutes(50))])
      ])
    ]),
    Row({
      title: () => `${done()} done today`,
      symbol: "checkmark.circle",
      tint: () => (done() > 0 ? cmux.theme.success : cmux.theme.text.secondary)
    })
  ])
}

globalThis.__cmuxAppExports = { renderFocus }
```

To add it to a customize app that already has a sidebar section, keep that
section and put `renderFocus()` inside its render (see "Adding a view" below).

## Where it shows, and errors

The first time cmux sees the sidebar section it adds it to the end of its
`defaultRegion` (`bottom` is the band under the workspace list). A person who
moves or removes it keeps that choice; cmux never adds it back. A v2 section is
named by its interface, so to put it back on purpose:

```sh
cmux apps place 'local/customize#cmux.section/1' --region bottom
```

The Session Info section appears in every chat's Session Info after the default
sections; the person can drag it.

When a section stays empty or shows an error, read the app's log (script
errors, failed loads, refused scopes):

```sh
cmux raw command --request-json '{"cmd":"apps-logs","app":"local/customize"}'
```

## Adding a view to an existing customize app

There is one customize app with one sidebar section and one Session Info
section. Read both files first and keep everything in them.

- If the slot the new view needs is free, add that interface to `implements`
  with a new render name, add the function to `main.js`, and add its name to
  the existing `globalThis.__cmuxAppExports` object.
- If the slot is taken (a second sidebar view), put the new view inside the
  existing section: give its render a group per view and keep the old one.
- Never write a second `__cmuxAppExports` assignment: the last one replaces the
  first, and the earlier sections stop rendering.

For example, reviews waiting on you under the 24-hour list, in the same
sidebar section:

```js
function renderReviews() {
  const [rows, setRows] = signal(null)
  const [error, setError] = signal(null)
  search("is:pr is:open review-requested:@me").then((items) => setRows(items.map(toRow)), (e) => setError(String(e)))
  return prList(rows, error, "No reviews waiting")
}

function renderSidebar() {
  return VStack({ spacing: 8 }, [renderRecent(), Text("Reviews"), renderReviews()])
}

globalThis.__cmuxAppExports = { renderSidebar, renderBranch }
```

and point `cmux.section/1`'s `export` at `renderSidebar`.
