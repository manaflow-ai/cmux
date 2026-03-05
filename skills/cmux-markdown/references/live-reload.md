# Live Reload Behavior

The markdown panel watches the file on disk and automatically re-renders when it changes. This enables real-time plan tracking as agents or editors update the file.

## How It Works

The panel uses a kernel-level file system watcher (`DispatchSource` with `O_EVTONLY`) that monitors the file for:

- **Write events** -- content was modified in place
- **Extend events** -- content was appended
- **Delete events** -- file was removed (atomic replace step 1)
- **Rename events** -- file was moved or renamed

## Supported Write Patterns

| Pattern | Supported | Notes |
|---------|-----------|-------|
| Direct write (`echo >>`) | Yes | Triggers write/extend event |
| Editor save (vim, nano) | Yes | Most editors use atomic write (see below) |
| Atomic replace (write tmp + rename) | Yes | Handled via delete/rename recovery |
| `sed -i` | Yes | Uses atomic replace internally |
| VS Code / IDE save | Yes | Uses atomic replace |
| Agent progressive writes | Yes | Each write triggers a re-render |

## Atomic File Replacement

Many editors and tools write files atomically: write to a temporary file, then rename it over the original. This shows up as a **delete** event followed by a new file appearing at the same path.

The panel handles this by:

1. Detecting the delete/rename event
2. Attempting to re-read the file immediately (in case the rename already happened)
3. If the file is missing, wait 500 ms and check again (the new file may not yet be in place)
4. Reconnecting the file watcher to the new inode

## File Unavailable State

If the file is deleted and does not reappear within the retry window, the panel shows a "file unavailable" state with the original path. The panel does not close automatically -- the user must close it manually.

If the file later reappears at the same path (e.g., the user recreates it), the panel does NOT automatically reconnect. Close and reopen the panel to pick up the new file.

## Performance

- Re-reads are dispatched to the main thread and run synchronously.
- Large files (100KB+) may cause brief UI hitches during re-render. For extremely large markdown files, consider splitting into smaller documents.
- The file watcher runs on a low-priority background queue and has negligible CPU impact.

## Tips for Agents

- **Write the full plan file first, then open it.** This avoids the panel showing a partially written file.
- **Append-style updates work well.** Adding sections to the end of a file triggers a smooth re-render.
- **Overwriting the entire file is fine.** The atomic replace handling ensures no data is lost.
- **Don't delete and recreate rapidly.** If writing a new version, prefer overwriting in place or using atomic replacement.
