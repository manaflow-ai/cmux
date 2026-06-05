---
name: cmux-notes
description: >-
  Create, read, edit, find, and organize project notes in the cmux per-workspace
  Notes tree (real Markdown files under .cmux/notes). Use whenever the user asks
  to take/save/jot/update/find notes, keep a running log, or file notes under a
  Claude session. Notes written here show up live in cmux's Notes sidebar tab.
---

# cmux Notes

cmux keeps **project notes as real Markdown files** in a per-workspace folder tree.
They are browsable and movable in cmux's **Notes** sidebar tab, and editing them
on disk updates the sidebar live (it watches the filesystem). Your job is to read,
write, edit, create, and organize these `.md` files using ordinary file tools.

## 1. Find the notes root

Resolve the workspace notes root **once** at the start, then work inside it.

1. **Preferred — environment variable.** cmux exports the absolute path:
   ```bash
   echo "$CMUX_WORKSPACE_NOTES_DIR"
   ```
   If non-empty, that directory is the workspace notes root. Use it.

2. **Fallback — resolve from the project.** If the variable is empty (older app,
   or running outside a cmux terminal), walk up from the current directory to the
   nearest ancestor containing `.cmux/`, then use `<that>/.cmux/notes/`. If exactly
   one subfolder there contains a `_workspace.json`, use it; otherwise operate at
   `<project>/.cmux/notes/` and tell the user the workspace folder will appear once
   they open the Notes tab.

Create the root on first write if it does not exist:
```bash
mkdir -p "$CMUX_WORKSPACE_NOTES_DIR"
```

## 2. Layout & conventions

```
$CMUX_WORKSPACE_NOTES_DIR/
  _workspace.json          # cmux marker — DO NOT edit or delete
  todo.md                  # a top-level ("global") note
  research/                # an ordinary folder you can make
    links.md
  auth-refactor-9c2f/      # a Claude session folder (has _session.json)
    _session.json          # cmux marker — DO NOT edit or delete
    plan.md                # a note filed under that session
```

- **Notes are `.md` files.** Use clear, kebab-case filenames (`api-design.md`).
- **Folders** group notes; nesting is allowed. "Global" just means a note at the
  workspace root rather than inside a folder.
- **Session folders** are directories containing a `_session.json` marker. File a
  note "under a session" by creating/moving it **inside** that folder.
- **Never create, edit, move, or delete `_workspace.json` or `_session.json`**, and
  ignore dotfiles. They are cmux-managed; touching them breaks the sidebar binding.

## 3. Operations

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

**Move / rename** (this is how you nest or "globalize" a note):
```bash
mv "$CMUX_WORKSPACE_NOTES_DIR/todo.md" "$CMUX_WORKSPACE_NOTES_DIR/research/"
```

**File a note under a Claude session**: find the session folder (a directory with
a `_session.json`) and create/move the note inside it.
```bash
# discover session folders and the session they point to
for d in "$CMUX_WORKSPACE_NOTES_DIR"/*/ ; do
  [ -f "$d/_session.json" ] && echo "$d -> $(cat "$d/_session.json")"
done
```

## 4. Retrieval

To answer "what did I note about X", search the tree:
```bash
grep -ril --include='*.md' "search terms" "$CMUX_WORKSPACE_NOTES_DIR"
```
Then Read the matches and summarize. Prefer the most-recently-modified file when
several match (`ls -t`).

## 5. Good habits

- Confirm the resolved root once, then keep paths relative to it.
- Keep one topic per note; link related notes by relative path.
- When the user is mid-session and says "note this", append to an existing relevant
  note if one clearly fits, otherwise create a new well-named note. Creating a new
  note is always safe — there is no limit.
- After writing, you can mention the note's path; the user will also see it appear
  in the Notes sidebar tab.
