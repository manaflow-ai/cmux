# Local app views

A complete example for the request "a view of the PRs from the last 24h". It
writes the customize app (`~/.config/cmux/customize`, id `local/customize`): a
sidebar section in the band under the workspace list, and a Session Info section
that lists the chat branch's pull requests. cmux watches the folder: each save
reloads the app, and the first save installs it with the scopes its manifest
asks for. There is no restart and no install click.

`cmux-tui/crates/cmux-app-manifest/tests/customize_example.rs` validates the two
files below exactly as written here.

## The manifest

`~/.config/cmux/customize/cmux-app.json`:

```json
{
  "$schema": "https://cmux.dev/schemas/cmux-app/1.json",
  "manifestVersion": 1,
  "id": "local/customize",
  "name": "My views",
  "version": "1.0.0",
  "description": "Pull requests from the last 24 hours, and the chat branch's pull requests.",
  "engines": { "cmux": "^1.0" },
  "main": "main.js",
  "scopes": {
    "net:api.github.com": "Search pull requests when GitHub is not connected.",
    "actions:run": "Open a pull request when you click its row."
  },
  "optionalScopes": {
    "integration:github:read": "Use the connected GitHub account, private repositories included."
  },
  "contributes": {
    "sidebarSections": [
      { "id": "recent", "title": "PRs · last 24h", "symbol": "clock.arrow.circlepath", "defaultRegion": "bottom", "render": "renderRecent", "maxRows": 10 }
    ],
    "sessionInfoSections": [
      { "id": "branch", "title": "Branch pull requests", "symbol": "arrow.triangle.pull", "render": "renderBranch", "maxRows": 8 }
    ],
    "settings": {
      "type": "object",
      "properties": { "login": { "type": "string", "title": "GitHub login", "default": "" } }
    }
  },
  "activation": ["onSidebarSection:recent", "onSessionInfoSection:branch"]
}
```

## The script

`~/.config/cmux/customize/main.js` is a plain classic script, not a module: no
`import` or `export`. The scene globals (`VStack`, `Row`, `ForEach`,
`EmptyState`, `signal`, `computed`, `cmux`, ...) are already defined, and the
script hands its render functions to cmux through `globalThis.__cmuxAppExports`.
A render function gets the mount context as its argument; a Session Info
section's is `{ session_id, cwd, branch?, harness? }`.

```js
const repoOf = (url) => String(url || "").replace("https://api.github.com/repos/", "")

// One GitHub search; `who` is "@me" through the connected account, else the login setting.
async function search(query) {
  const login = String(cmux.app.settings().login || "").trim()
  try {
    const r = await cmux.integrations.github.request({ method: "GET", path: `/search/issues?q=${encodeURIComponent(query("@me"))}&per_page=50` })
    return r.items
  } catch (e) {
    if (!login) throw new Error("Connect GitHub, or set the login setting of My views.")
    const r = await cmux.net.fetch(`https://api.github.com/search/issues?q=${encodeURIComponent(query(login))}&per_page=50`, { headers: { Accept: "application/vnd.github+json" } })
    if (!r.ok) throw new Error(`GitHub answered ${r.status}`)
    return r.json().items
  }
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
      }).onTap(() => cmux.actions.run("openBrowser", { url: p().url }))
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
      const batches = await Promise.all(["author", "review-requested", "assignee"].map((role) => search((who) => `is:pr ${role}:${who} updated:>=${since}`)))
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
      setRows((await search(() => `is:pr head:${branch}`)).map(toRow))
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

## Where it shows, and errors

The first time cmux sees the `recent` section it adds it to the end of its
`defaultRegion` (`bottom` is the band under the workspace list). A person who
moves or removes it keeps that choice; cmux never adds it back. To put it back
on purpose:

```sh
cmux apps place local/customize#recent --region bottom
```

The `branch` section appears in every chat's Session Info after the default
sections; the person can drag it.

When a section stays empty or shows an error, read the app's log (script
errors, failed loads, refused scopes):

```sh
cmux raw command --request-json '{"cmd":"apps-logs","app":"local/customize"}'
```

## Adding a section to an existing customize app

There is one customize app, so a new view goes into the same two files. Read
them first and keep everything already there:

1. Add an entry with a new id and a new render name to `sidebarSections` (or
   `sessionInfoSections`), next to the existing entries, and add
   `onSidebarSection:<id>` (or `onSessionInfoSection:<id>`) to `activation`.
2. Add the render function to `main.js` and add its name to the existing
   `globalThis.__cmuxAppExports` object. Do not write a second
   `__cmuxAppExports` assignment: the last one replaces the first, and the
   earlier sections stop rendering.

For example, a "Reviews" section next to `recent`:

```json
{ "id": "reviews", "title": "Reviews", "symbol": "person.2", "defaultRegion": "bottom", "render": "renderReviews", "maxRows": 8 }
```

```js
function renderReviews() {
  const [rows, setRows] = signal(null)
  const [error, setError] = signal(null)
  search((who) => `is:pr is:open review-requested:${who}`).then((items) => setRows(items.map(toRow)), (e) => setError(String(e)))
  return prList(rows, error, "No reviews waiting")
}

globalThis.__cmuxAppExports = { renderRecent, renderBranch, renderReviews }
```

Each section is placed once, on its own: moving `recent` does not move
`reviews`.
