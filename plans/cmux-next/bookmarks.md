# cmux next: bookmarks

Written 2026-09-30 for the user request "we need to support bookmarks, have
UI for that?". Branch `feat-cmux-next-bookmarks`. Chrome parity, scoped per
browser profile (data-model.md 5), stored as personal state in the home
session (data-model.md 1.2c).

## 1. Model

A bookmark tree per browser profile. Two fixed roots, as in Chrome: the
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
profile's bookmarks (Chrome shows bookmarks in incognito) and write to them
only on an explicit Bookmark action, as Chrome does.

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
  last_used_ms INTEGER
);
CREATE INDEX IF NOT EXISTS bookmarks_parent ON bookmarks(browser_profile_id, parent_id, position);
```

Commands (each change bumps a per-session `bookmarks_revision`, journals,
and emits `bookmarks-changed {browser_profile_id, bookmarks_revision}`):

- `list-bookmarks {browser_profile_id}` → `{bookmarks_revision, bookmarks:[node]}`,
  ordered by parent then index. Node JSON: `{id, browser_profile_id, parent,
  kind, index, title, url?, favicon_key?, source_key?, created_ms,
  last_used_ms?}`.
- `create-bookmark {browser_profile_id, parent, index?, kind, title, url?,
  favicon_key?, source_key?, created_ms?, id?}` → `{bookmark, changed}`; an
  existing `id` returns the stored node with `changed:false` (idempotent
  retries). Absent `index` appends.
- `update-bookmark {id, title?, url?, favicon_key?, last_used_ms?}`; absent
  keeps, null clears `favicon_key` / `last_used_ms`.
- `move-bookmark {id, parent, index}` (same profile; refuses a cycle).
- `delete-bookmark {id}` → `{deleted:[ids]}` (subtree).
- `import-bookmarks {browser_profile_id, parent, index?, source_key?,
  replace?, nodes:[{kind, title, url?, created_ms?, children?:[...]}]}` → `{root_ids,
  count}`: one transaction. With `source_key` and `replace:true`, the folder
  of that profile carrying `source_key` is emptied and refilled in place (or
  created at `parent`/`index` when missing). Used by the HTML import and the
  onboarding import.

Errors: `invalid_params` for a bad parent, kind, URL or cycle; `not_found`
for an unknown id.

## 3. Surfaces (action contract)

| Surface | Behavior |
| --- | --- |
| Omnibar star | at the trailing end of the address field; hollow when the page is not bookmarked, filled when it is. Click: bookmarks the page into the last-used folder (default Bookmarks Bar) and opens the edit bubble; on a bookmarked page it opens the bubble. |
| Edit bubble | popover from the star: Name, Folder (popup of every folder), Remove, Done, More… (manager at the node). Return saves, Escape closes. |
| Bookmarks bar | under a browser pane's toolbar, off by default (`browser.showBookmarksBar`). Bookmarks Bar children left to right; folders open as menus; an overflow chevron menu holds what does not fit plus Other Bookmarks; drag reorders within the bar; right-click: Open, Open in New Tab, Edit…, Delete, Add Folder…, Show Bookmarks Bar, Bookmark Manager. |
| `cmux://bookmarks` | native page like `cmux://history`: folder tree on the left, list on the right, search field, drag to reorder and to move into folders, edit and delete, Add Bookmark, Add Folder, Import (HTML), Export (HTML). |
| Omnibar suggestions | bookmark rows (star icon) ranked with Chrome's rule: every typed term must prefix a word of the title or match the URL; bookmarks beat plain history for the same match quality. |
| Palette | Bookmark This Page, Bookmark All Tabs…, Open Bookmark… (palette page of every bookmark), Show/Hide Bookmarks Bar, Bookmark Manager, Import Bookmarks…, Export Bookmarks…. |
| CLI | `cmux bookmark list|add|remove|open|move|import|export` |

### 3.1 Keys

Chrome binds Cmd-D (bookmark), Cmd-Shift-D (bookmark all tabs), Cmd-Shift-B
(bookmarks bar) and Cmd-Opt-B (manager). cmux already uses Cmd-D (Split
Right, tier 1; kept in pages by the round 3 decision), Cmd-Shift-D (Split
Down) and Cmd-Opt-B (right sidebar). Defaults:

| Action | Default | Tier |
| --- | --- | --- |
| `bookmark.toggleBar` Show Bookmarks Bar | Cmd-Shift-B (Chrome; free in cmux) | 1 |
| `bookmark.addPage` Bookmark This Page | none by default (Cmd-D is Split Right); the star and the palette | 2 |
| `bookmark.manager` Bookmark Manager | none (Cmd-Opt-B is the right sidebar) | 1 |

All are editable in the palette's shortcut recorder and in cmux.json.

## 4. Extensions

`chrome.bookmarks` in the CEF Chrome runtime works today against Chromium's
own per-profile `BookmarkModel` (extensions-matrix.md: create, search and
remove pass, with Chromium's "Bookmarks Bar" and "Other Bookmarks"). That
model is not cmux's. Routing it to cmux needs a fork bridge (section 6).

## 5. Places

A terminal location bookmark ("place") was considered. See the status
section for the decision.

## 6. Status

See the end of this file (updated as work lands).
