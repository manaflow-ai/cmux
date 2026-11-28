# cmux next: bookmarks

Written 2026-09-30 for the user request "we need to support bookmarks, have
UI for that?". Branch `feat-cmux-next-bookmarks`. Scoped per
browser profile (data-model.md 5), stored as personal state in the home
session (data-model.md 1.2c).

## 1. Model

A bookmark tree per browser profile. Two fixed roots, the same as Chromium's
bookmark model: the
**Bookmarks Bar** (`bar`) and **Other Bookmarks** (`other`). The roots are
not rows; they are reserved parent values. Every other node is a row:

| Field | Meaning |
| --- | --- |
| `id` | `bm_<32 lowercase hex>`, minted by the writer (daemon or app) |
| `browser_profile_id` | `default` or a browser profile UUID |
| `parent` | `bar`, `other`, or the id of a folder in the same profile |
| `kind` | `url` or `folder` |
| `index` | position among its siblings (0-based, dense) |
| `title` | display name (≤ 4 KiB; may be empty for a URL, then the URL shows) |
| `url` | absolute URL (`url` kind only, ≤ 64 KiB) |
| `favicon_key` | cache key of the favicon (the page's origin today), or null |
| `source_key` | folders made by a browser import: the import source (`<browser>/<profile dir>`), so a re-import replaces that folder; else null |
| `created_ms` | creation time (an import keeps the source's date added) |
| `last_used_ms` | last open from any bookmark surface, or null |
| `icon` | folders only (`bookmark-icon-v1`): the shared icon string (one emoji, an SF Symbol name, or a stored `image:`/`svg:sha256-<hex>` asset), or null |

Rules: a folder may not move into itself or a descendant; nodes never move
between profiles (Move to Browser Profile copies); deleting a folder deletes
its subtree; deleting a browser profile deletes its bookmarks in the same
transaction. Limits: 100,000 nodes per profile, depth 64.

## 2. Storage and ownership

| Where | When |
| --- | --- |
| home session table `bookmarks` (capability `bookmarks-v1`) | the home daemon serves it |
| `<Application Support>/<bundle id>/BrowserProfiles/bookmarks.json` | older home daemon (the pinned cmux-tui until the pin moves) |

The app copies the file into the daemon once when the daemon gains
`bookmarks-v1`, then deletes the file. Incognito windows read the default
profile's bookmarks and write to them
only on an explicit Bookmark action.

### 2.1 Daemon protocol (`bookmarks-v1`, home session only)

```sql
CREATE TABLE IF NOT EXISTS bookmarks (
  bookmark_id TEXT PRIMARY KEY NOT NULL,
  browser_profile_id TEXT NOT NULL,
  parent_id TEXT NOT NULL,              -- 'bar' | 'other' | a folder bookmark_id
  kind TEXT NOT NULL CHECK(kind IN ('url','folder')),
  position INTEGER NOT NULL CHECK(position >= 0),
  title TEXT NOT NULL,
  url TEXT,
  favicon_key TEXT,
  source_key TEXT,
  created_ms INTEGER NOT NULL,
  last_used_ms INTEGER,
  icon TEXT                             -- folders only; added by bookmark-icon-v1
);
CREATE INDEX IF NOT EXISTS bookmarks_parent ON bookmarks(browser_profile_id, parent_id, position);
```

Commands (each change bumps a per-session `bookmarks_revision`, journals,
and emits `bookmarks-changed {browser_profile_id, bookmarks_revision}`):

- `list-bookmarks {browser_profile_id}` → `{bookmarks_revision, bookmarks:[node]}`,
  ordered by parent then index. Node JSON: `{id, browser_profile_id, parent,
  kind, index, title, url?, favicon_key?, source_key?, created_ms,
  last_used_ms?, icon?}`.
- `create-bookmark {browser_profile_id, parent, index?, kind, title, url?,
  favicon_key?, source_key?, created_ms?, bookmark?}` → `{bookmark, changed}`; an
  existing `id` returns the stored node with `changed:false` (idempotent
  retries). Absent `index` appends.
- `update-bookmark {bookmark, title?, url?, favicon_key?, last_used_ms?, icon?}`;
  absent keeps, null clears `favicon_key` / `last_used_ms` / `icon`. `icon`
  (`bookmark-icon-v1`) is for folders only (refused on a `url` node); an asset
  icon must name a stored blob. Create and import take no icon; a replacing
  import keeps its folder's icon.
- `move-bookmark {bookmark, parent, index}` (same profile; refuses a cycle).
- `delete-bookmark {bookmark}` → `{deleted:[ids]}` (subtree).
- `import-bookmarks {browser_profile_id, parent, index?, source_key?,
  replace?, nodes:[{kind, title, url?, created_ms?, children?:[...]}]}` → `{root_ids,
  count}`: one transaction. With `source_key` and `replace:true`, the folder
  of that profile carrying `source_key` is emptied and refilled in place (or
  created at `parent`/`index` when missing). Used by the HTML import and the
  onboarding import.

Every write carries the exactly-once key `origin` + `mutation_id` (optional
on these raw commands, required by the later v2 `bookmark.*` port); the app
mints one per logical write and reuses it on retries, and the file-to-daemon
copy keys each node `migrate-file-<id>`. Results carry `replayed`.

Errors: `invalid_params` for a bad parent, kind, URL or cycle; `not_found`
for an unknown id.

## 3. Surfaces (action contract)

| Surface | Behavior |
| --- | --- |
| Omnibar star | at the trailing end of the address field; hollow when the page is not bookmarked, filled when it is. Click: bookmarks the page into the last-used folder (default Bookmarks Bar) and opens the edit bubble; on a bookmarked page it opens the bubble. |
| Edit bubble | popover from the star: Name, Folder (popup of every folder), Remove, Done, More… (manager at the node). Return saves, Escape closes. |
| Bookmarks bar | under a browser pane's toolbar, off by default (`browser.showBookmarksBar`). Bookmarks Bar children left to right; folders open as menus; an overflow chevron menu holds what does not fit plus Other Bookmarks; drag reorders within the bar; right-click: Open, Open in New Tab, Edit…, Delete, Add Folder…, Show Bookmarks Bar, Bookmark Manager. |
| `cmux://bookmarks` | native page like `cmux://history`: folder tree on the left, list on the right, search field, drag to reorder and to move into folders, edit and delete, Add Bookmark, Add Folder, Import (HTML), Export (HTML). |
| Omnibar suggestions | bookmark rows (star icon) ranked by one rule: every typed term must prefix a word of the title or match the URL; bookmarks beat plain history for the same match quality. |
| Palette | Bookmark This Page, Bookmark All Tabs…, Open Bookmark… (palette page of every bookmark), Show/Hide Bookmarks Bar, Bookmark Manager, Import Bookmarks…, Export Bookmarks…. |
| CLI | `cmux bookmark list|add|remove|open|move|import|export` |

### 3.1 Keys

The usual browser chords are Cmd-D (bookmark), Cmd-Shift-D (bookmark all tabs),
Cmd-Shift-B (bookmarks bar) and Cmd-Opt-B (manager). cmux already uses Cmd-D (Split
Right, tier 1; kept in pages by the round 3 decision), Cmd-Shift-D (Split
Down) and Cmd-Opt-B (right sidebar). Defaults:

| Action | Default | Tier |
| --- | --- | --- |
| `bookmark.toggleBar` Show Bookmarks Bar | Cmd-Shift-B (free in cmux) | 1 |
| `bookmark.addPage` Bookmark This Page | none by default (Cmd-D is Split Right); the star and the palette | 2 |
| `bookmark.manager` Bookmark Manager | none (Cmd-Opt-B is the right sidebar) | 1 |

All are editable in the palette's shortcut recorder and in cmux.json.

## 4. Extensions

`chrome.bookmarks` shows cmux's bookmarks: Chromium's per-profile
`BookmarkModel` is a cache of cmux's tree, kept in sync both ways (fork API
22, manaflow-ai/cef#17; cx-d0d.37).

- Fork: `cmux_bookmarks_sync(profile, tree)` makes the local Bookmarks bar
  and Other bookmarks equal to cmux's tree with the fewest model operations,
  so extensions get `onCreated`, `onChanged`, `onMoved` and `onRemoved` only
  for real differences. `cmux_bookmarks_observe` reports every other change
  (added with its subtree, changed, moved, removed, reordered, reset, and
  "loaded" when the model is ready). Changes made by a sync are not
  reported, so nothing echoes. Mobile and managed bookmarks and account
  storage are left alone.
- Ids: a cmux id `bm_<32 hex>` is that UUID in Chromium, so no map is kept.
  Roots: `bar` is `bookmark_bar_node`, `other` is `other_node`.
- Stores: every persistent Chromium profile of a cmux profile (its own and
  its remote-localhost stores) is synced. Incognito contexts read the regular
  profile's model in Chromium.
- Start: a store syncs when its model loads, and only once cmux's tree for
  that profile is loaded (the daemon's reply or the file), so cmux wins at
  startup and a placeholder never empties Chromium's model. An extension
  change that arrives before then is dropped by that first sync.
- After that, cmux syncs a profile's stores after every change of its tree,
  and an extension's change is applied to cmux as an ordinary operation
  (create with the node's id, update, move, delete). An operation cmux
  refuses (for example a URL cmux does not accept) is undone in Chromium by
  syncing that store again. An extension's new bookmark does not change the
  folder the star uses next.
- Engines without the bridge (fork API < 22) keep Chromium's own tree, as
  before. The extension suite (`ext_e2e/bookmark_bridge.py`) records the
  checks as unsupported there.

## 5. Places (terminal locations): left out

A "place" (workspace, cwd, optional command) does not fit the bookmark
tree cleanly. Bookmarks are scoped per browser profile (the extension model,
Netscape HTML, `chrome.bookmarks`), while a place belongs to a machine and
a space; a place in the tree would break the HTML export and show to
extensions as a non-URL node. A command in a bookmark is also a code path
that imported files could carry. The location trail (history.md 4.2), Go to
Workspace and the proposed workspace templates (`layout-templates-v1`) cover
the need with the right owner. Revisit as a space-scoped "Saved Places" list
if dogfood asks.

## 6. Status (2026-09-30, branch feat-cmux-next-bookmarks)

Built: the model and its tests (CmuxNextBookmarks), the local file store,
migration of the file into the daemon and of earlier onboarding imports
(once, marker file `bookmarks-imports-migrated`), the `ImportedBookmarkSink`
conformance agreed with the onboarding agent, the omnibar star and edit
bubble, the bookmarks bar (Cmd-Shift-B, `browser.showBookmarksBar`, overflow
chevron, Other Bookmarks, folder menus, drag reorder, link drop), the
`cmux://bookmarks` manager, bookmark rows in omnibar suggestions, the palette
page Open Bookmark…, `cmux bookmark …` verbs and `bookmark.list`, the
`debug.bookmarks` control method, the Settings toggle.

Daemon: `bookmarks-v1` is served by cmux-tui and listed in the app's
`optional` capabilities; builds bundle the daemon of their own cmux-tui tree
(scripts/cmux-next/pin-cmux-tui.sh), so the file is used only with an older
remote daemon.

Verified on tag nxbm (no-activate launch, control socket, window
screenshots; the app never became active and no window became key): the
star turns filled after `cmux bookmark add-page` and opens the edit bubble
under it; `cmux bookmark toggle-bar` writes `browser.showBookmarksBar` and
shows the bar with folders, the overflow chevron and Other Bookmarks;
`cmux bookmark manager` opens `cmux://bookmarks`; Open Bookmark… lists every
bookmark with its folder path; export, import (into an Imported folder),
list, search and remove work from the CLI; bookmarks survive relaunch.
Not verified live: omnibar bookmark rows (typing into the omnibar of a
non-key window did not reach the field; ranking is unit tested), drag
reorder on the bar and in the manager, the bubble's Remove and folder change.

Favicons on the bar and in its menus: the site's icon (an open tab's on the
bookmark's origin, else the origin's `/favicon.ico`); a bar drawn while one
loads redraws when it lands. Bookmark All Tabs saves every pane of the
window (#19071). An incognito omnibar offers the default profile's bookmarks
(scripts/cmux-next/bookmarks-incognito-omnibar-live.py). The
`chrome.bookmarks` bridge is built (section 4) and ships with fork API 22.
Not built: a dedicated sync with other Macs.
