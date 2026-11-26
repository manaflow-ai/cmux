# To Do (`cmux/todo`): a to-do list widget in the shape of Apple's Reminders widget

A `cmux.widget/1` store app. The person installs it from the App Store with one click (it is not
installed by default: no `BUNDLED` marker; the `STORE` marker lists it), then adds it to the New Tab
page or the sidebar from Edit Widgets. On first install it shows an empty list with New item ready.

| Size | What it shows |
| --- | --- |
| small (1x1) | the count of open items, the list's name in the list's color, the first three items, "N more"; New item while the list is empty |
| medium (2x1) | count and name on the left; three items and New item on the right |
| large (2x2) | count and name, seven items, New item, and the done items folded into one "N Completed" row that opens them (with Clear) |

- Click a row to check it off: the circle fills, the text strikes through and the row slides out of
  the open list (the SDK's `RowList` with `check` and `done`; the host animates it, a crossfade
  under Reduce Motion). In large, a done row under Completed un-checks on a click.
- A render that throws keeps its last good scene on the tile, marked stale (`apps-widget-health`),
  and is mounted again with backoff; the widget does not catch that itself.
- Type in New item and press Return to add to the end. Right-click a row for Mark as done / Delete.
- The Add Widget gallery's preview (`preview: true` in the mount context) draws sample items and
  never reads or writes storage.

## Settings

`title`: the list's name (the tile's own setting, else the app's). Empty means "To Do".

`color`: the list's color, one of Reminders' (red, orange, yellow, green, blue, purple, brown) or a
`#RRGGBB` hex; blue by default. It tints the name, the filled checkboxes and New item's plus. It is
passed as a hex because the theme's `accent` is the text color by default.

## Storage and sync

Each item is its own key, `item:<id>`, holding `{id, text, done, created, updated, by, doneAt?,
deleted?}`, in the app's storage (`storage:local`). Every placed tile shares one copy of the list.

The model (`src/model.ts`) is built for a synced store: two devices that change different items
never overwrite each other (one key each), and the same item changed on both resolves to the later
change (`updated`, ties by the writing device's id `by`). A delete is a tombstone (`deleted: true`)
so it does not come back from a device that missed it; tombstones older than 30 days are dropped
(a device offline longer than that can bring a deleted item back).
The widget re-reads and merges on `app.storage.changed` (the event synced storage sends when another
device changed the app's keys), and a read never undoes a change made while it was in flight. After
each read it writes back every item whose shown copy is newer than the stored one, so storage that
keeps whichever write arrived last still ends at the newest version on every device, and a save that
failed is retried; its warning stays until it is saved.

Today cmux has no synced app storage: `app.storage.*` is a local SQLite table per app
(`cmux-tui/crates/cmux-tui-core/src/apps/storage.rs`), and `storage:synced` is an allowed scope
with nothing behind it. Once synced storage exists, this app asks for `storage:synced` and works
across the person's Macs and iPhone with no other change; `test/widget.test.ts` ("sync across two
devices") runs two devices over a synced store that behaves that way.

## Files

- `src/model.ts`: items, merge, which items each size shows; no view, no host.
- `src/store.ts`: the shared list, reads and writes through `cmux.storage`.
- `src/main.ts`: `renderTodo`, the scene for each size, public SDK only.
- `src/l10n.ts`, `strings/{en,ja}.json`: strings.
- `test/`: `bun test first-party-apps/widget-todo/test` (model, first install, add, check off,
  persistence across a restart, the preview, and two devices syncing).
- `preview/build.ts` writes `webviews/src/apps/scene/fixtures/todo-widget-scenes.json`, the scene ops for each gallery variant over a
  sample list; the webviews gallery entry `apps.todo-widget` draws them
  (`webviews/src/apps/scene/TodoWidget.gallery.tsx`).

## Gaps in the platform

- A checked row leaves the open list at once: Reminders keeps it struck through for about a second
  first. The SDK has no "leave after" for a row, so the strike shows during the slide only.
- The web page does not draw `apps-widget-health` yet: only the daemon and `cmux ext dev` read it,
  so a stale tile looks fresh in the New Tab page.
- The web scene maps SF symbol names from a short table without `circle`, so the checkbox is
  drawn with shapes (`ListItem.check`) instead of `circle` / `checkmark.circle.fill`.
