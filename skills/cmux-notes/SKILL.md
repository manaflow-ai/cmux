---
name: cmux-notes
description: >-
  Create, read, edit, find, and organize project notes in the cmux per-workspace
  Notes tree (real Markdown files under .cmux/notes). Use whenever the user asks
  to take/save/jot/update/find notes, keep a running log, or file notes under an
  agent session. Read notes starting from your own session's folder, then the
  workspace, then project-wide. Notes written here show up live in cmux's Notes
  sidebar tab.
---

# cmux Notes

cmux keeps **project notes as real Markdown files** in a per-workspace folder tree.
They are browsable and movable in cmux's **Notes** sidebar tab, and editing them
on disk updates the sidebar live (it watches the filesystem). Your job is to read,
write, edit, create, and organize these `.md` files using ordinary file tools.

> **Beta gate.** The Notes *sidebar tab* is a beta surface behind the "Notes"
> toggle in Settings → Beta Features (`rightSidebar.beta.notes.enabled`). While
> it is off, `$CMUX_WORKSPACE_NOTES_DIR` is not exported to new terminals and
> the sidebar tab is hidden — but `cmux note …` commands and note files keep
> working (use the fallback below to resolve the notes root). Only suggest
> enabling the beta when the user wants the sidebar tree UI.

## 1. Find the notes root

Resolve the workspace notes root **once** at the start, then work inside it.

1. **Preferred — environment variable.** cmux exports the absolute path:
   ```bash
   echo "$CMUX_WORKSPACE_NOTES_DIR"
   ```
   If non-empty, that directory is the workspace notes root. Use it.

2. **Fallback — resolve from the project.** If the variable is empty (older app,
   or running outside a cmux terminal), walk up from the current directory to the
   nearest ancestor containing `.cmux/` and use `<that>/.cmux/notes/` as the notes
   root. If no ancestor has a `.cmux/`, cmux treats the current directory as the
   project root and uses `<cwd>/.cmux/notes/`. Then pick the workspace subfolder
   whose `_workspace.json` binds your cwd:
   ```bash
   find <notes-root> -maxdepth 2 -name '_workspace.json' -print -exec cat {} \;
   # use the folder whose "cwd" matches your project directory
   ```
   If none matches, operate at the notes root and tell the user the workspace
   folder will appear once they open the Notes tab.

Create the root on first write if it does not exist:
```bash
mkdir -p "$CMUX_WORKSPACE_NOTES_DIR"
```

## 2. Layout & conventions

```
$CMUX_WORKSPACE_NOTES_DIR/
  _workspace.json          # cmux marker — DO NOT edit or delete
  todo.md                  # a workspace-root note
  research/                # an ordinary folder you can make
    links.md
  auth-refactor-9c2f/      # an agent session folder (has _session.json)
    _session.json          # cmux marker — DO NOT edit or delete
    plan.md                # a note filed under that session
```

- **Notes are `.md` files.** Use clear, kebab-case filenames (`api-design.md`).
- **Folders** group notes; nesting is allowed.
- **Session folders** are directories containing a `_session.json` marker
  (`{agent, sessionId, cwd, title, modified}`). File a note "under a session" by
  creating/moving it **inside** that folder.
- **Terminal rows** (sidebar-only): the workspace's live terminal panes also
  appear in cmux's Notes tab as virtual folders, with their attached `cmux note`
  notes and agent sessions nested beneath them. They are not directories on
  disk — never look for (or try to create) them in the filesystem.
- **Never create, edit, move, or delete `_workspace.json` or `_session.json`**, and
  ignore dotfiles. They are cmux-managed; touching them breaks the sidebar binding.
  If your session has no folder yet, don't fabricate one — write at the workspace
  root instead (cmux materializes session folders itself).

## 3. Scopes — read narrow to wide

Notes exist at three widening scopes. When the user asks you to consult notes
("check my notes", "what did we decide about X"), **start narrow and widen** until
you find what they mean — unless they name a scope ("all project notes"), then go
straight there.

1. **Your session's folder** — notes filed under the cmux session you are running
   in: the session folder whose `_session.json` carries your session id (compare
   `$CLAUDE_SESSION_ID` when set, or your harness's session id). To inspect them:
   ```bash
   find "$CMUX_WORKSPACE_NOTES_DIR" -name '_session.json' -print -exec cat {} \;
   ```
   (Use `find`, not a `*/` glob — zsh aborts the whole command when a glob
   matches nothing, and workspaces with no session folders are common.)
   If you can't match an id, take the folder for your agent with the newest
   `modified`. No session folder existing is normal — move on to the workspace.
2. **The workspace** — everything under `$CMUX_WORKSPACE_NOTES_DIR`, including
   other sessions' folders and root-level notes.
3. **Project-wide ("global")** — the parent `…/.cmux/notes/` directory: flat
   `cmux note` notes (see §5) plus sibling workspace folders belonging to the
   project's other cmux workspaces.

When **writing**: default new notes to the workspace root; use your own session
folder when the note is specifically about this session's work; write into another
workspace's folder only when the user explicitly asks.

## 4. Operations

Use your normal tools (Read, Write, Edit, Glob) and these shell commands. Always
quote paths — they can contain spaces.

**List / tree**
```bash
find "$CMUX_WORKSPACE_NOTES_DIR" -name '*.md' -not -path '*/.*' | sort
```

**Read** a note: open it with the Read tool (or `cat`).

**Create** a note (top-level or in a folder):
```bash
mkdir -p "$CMUX_WORKSPACE_NOTES_DIR/research"
# then Write the file:  $CMUX_WORKSPACE_NOTES_DIR/research/links.md
```
Prefer a short H1 title as the first line, e.g. `# API design`.

**Edit** a note: use the Edit tool on its path, or append:
```bash
printf '\n- new bullet\n' >> "$CMUX_WORKSPACE_NOTES_DIR/todo.md"
```

**New folder**
```bash
mkdir -p "$CMUX_WORKSPACE_NOTES_DIR/meeting-notes"
```

**Rename** (keep the `.md` extension):
```bash
mv "$CMUX_WORKSPACE_NOTES_DIR/todo.md" "$CMUX_WORKSPACE_NOTES_DIR/roadmap.md"
```

**Move** a note or folder (this is how you nest or un-nest):
```bash
mv "$CMUX_WORKSPACE_NOTES_DIR/todo.md" "$CMUX_WORKSPACE_NOTES_DIR/research/"
```

**File a note under an agent session**: find the session folder (a directory with
a `_session.json`, see §3) and create/move the note inside it. If the session has
no folder on disk yet (its row in the sidebar is virtual), write at the workspace
root instead — only cmux can materialize session folders.

## 5. Flat `cmux note` notes (index-owned) — CLI only

cmux also has a flat, index-managed note system: notes created from pane tab bars
or `cmux note new` live under `…/.cmux/notes/` tracked by an `index.json` (their
body files may have UUID names). Manage these with the `cmux` CLI, never with raw
file moves:

```bash
cmux note list                       # slugs, titles, attachment links
cmux note here                       # the note for the current pane/workspace
cmux note read <slug>
cmux note append <slug> "more text"  # also: write, path, open, new, rm
```

- **Never `mv` or rename their body files** — `index.json` pins the body path, and
  a raw move orphans the record (the note vanishes from `cmux note` and panes).
  Renaming them is done in cmux — the title field at the top of the note editor,
  or the Notes sidebar — which retitles the index record in place.
- Unsure whether a file is index-owned? Check before moving it:
  ```bash
  grep -F "$(basename "$note_file")" "<project>/.cmux/notes/index.json"
  ```
  No match → it's a plain tree note; move/rename freely.
- Reading a body directly is fine (`cmux note path <slug>` prints its path).

## 6. Retrieval

To answer "what did I note about X", search narrow → wide (§3):
```bash
grep -ril --include='*.md' "search terms" "$CMUX_WORKSPACE_NOTES_DIR"              # workspace
grep -ril --include='*.md' "search terms" "$(dirname "$CMUX_WORKSPACE_NOTES_DIR")" # project-wide
```
Then Read the matches and summarize. Prefer the most-recently-modified file when
several match (`ls -t`). Include `cmux note list` titles when the question spans
the whole project.

## 7. Good habits

- Confirm the resolved root once, then keep paths relative to it.
- Keep one topic per note; link related notes by relative path.
- When the user is mid-session and says "note this", append to an existing relevant
  note if one clearly fits, otherwise create a new well-named note. Creating a new
  note is always safe — there is no limit.
- After writing, you can mention the note's path; the user will also see it appear
  in the Notes sidebar tab.
