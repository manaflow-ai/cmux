# Markdown table column widths that outlive the tab

User, 2026-10-20: "make sure markdown tables have memory somehow like i close tab and reopen it and
the custom widths i set are gone.. is there file metadata we can write efficiently to".

## Why they were lost

`tables.ts` already saved widths per file, in the page's `localStorage`. Every cmux page runs in a
`WKWebsiteDataStore.nonPersistent()` store (`PageWebView+Pooled.swift`), so that storage dies with
the page's web content process. Close the tab (or relaunch) and the widths are gone.

## Where they live now

1. **The file's extended attribute `com.cmux.markdown.tables`** (primary). Small compact JSON, the
   page's own value: `{"v":1,"tables":[{"i":0,"h":"2-1a2b3c4d","w":[220,100]}]}`.
   - It travels with the file: rename, move on the volume, Finder copy, Time Machine, AirDrop.
   - It changes neither the file's bytes nor its modification time (only ctime). So git, the
     page's save hash, the file watch (`FileChangeWatch` compares size, mtime and inode) and other
     editors never see a resize. GFM has no column widths, so writing them into the text is not an
     option; HTML comments in the file would be an edit the user did not make.
   - Cost: one `setxattr(2)`, about 35 us p50 on this Mac under load (C probe, 2,000 writes).
   - Limits: APFS and HFS+ keep it; some SMB shares, FAT and exFAT refuse it (or keep `._` files);
     a file the user cannot write refuses it; editors that save by writing a new file and renaming
     it over (most of them, and `git checkout`) drop it; `git clone` never carries it.
2. **An app-side copy** under `~/Library/Application Support/<bundle id>/MarkdownTableWidths/`, one
   small JSON file per canonical path (SHA-256 of the path as its name, the path inside to guard
   collisions). Every write goes to both, so the copy answers whenever the attribute is missing
   (refused, or dropped by an editor that replaced the file). It is keyed by path, not inode, on
   purpose: a replaced file has a new inode, and that is the case it exists for. It keeps the 1,000
   most recently used files (read touches the mtime; pruned on the first write and every 32
   writes). Cost: one atomic write of under 1 KB, about 0.7 ms p50 here, off the main actor.

Read order: the attribute, then the copy. Both sit behind `MarkdownTableWidthStoring`
(`MarkdownTableWidthRepository`, an actor), with `ExtendedAttributeAccess` as the test seam for a
volume that refuses attributes.

## Which table is which

A table is known by its index among the file's tables and a key of its header row (`headerKey`:
cell texts, FNV-1a 32-bit, plus the column count). So:

- an edit anywhere else keeps the widths;
- a table added or removed above moves the widths with their table (the one saved table with that
  header);
- a changed header (or column count) shows natural widths, and the stale entry is dropped on the
  next write.

## When it reads and writes

- **Read** before first layout: the host reads the store while it builds the page's config and
  sends the value as `tableWidths`. The table view applies it in its constructor, so a saved table
  never jumps from its natural width.
- **Write** once per finished resize: at the end of a drag (mouseup) or on a double-click fit. A
  drag frame only restyles `<col>` elements; nothing is sent until the drag ends. The page sends
  `cmux.markdown.setTableWidths {path, value}`; the host checks the path is the tab's file and the
  value has the expected shape and size (16 KB, 256 tables, 256 columns).

## Reset

- Right-click on a table: **Reset Column Widths** (the page tells the host which table a right-click
  was on through `cmux.markdown.contextTable`; WebKit dispatches `contextmenu` before it asks the
  app for the menu, so the item shows only on tables).
- Command palette: **Markdown: Reset Table Column Widths** (`markdownResetTableWidths`) forgets every
  table of the file. Being a catalog action it is also the CLI (`cmux browser
  markdown-reset-table-widths`) and the MCP tool.
- No animation: the table snaps to natural widths, so the motion gate has nothing to gate.

## Not done

- No sync between Macs: the attribute travels with the file only where the file goes byte-for-byte
  with metadata (not git, not most cloud drives).
- The dev page and an older host keep the page-only `localStorage` store.
