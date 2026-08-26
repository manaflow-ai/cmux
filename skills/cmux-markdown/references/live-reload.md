# Live Reload Behavior

The panel watches the file with a kernel-level watcher (`DispatchSource` with `O_EVTONLY`) for write, extend, delete, and rename events, and re-renders on change.

## Supported write patterns

Direct writes (`echo >>`), editor saves, atomic replace (write temp then rename), `sed -i`, VS Code/IDE saves, and progressive agent writes all work. Most of these are atomic replace under the hood.

## Atomic file replacement

An atomic replace shows up as a delete event followed by a new file at the same path. The panel detects it, re-reads immediately (in case the rename already landed), waits 500 ms and checks again if the file is missing, then reconnects the watcher to the new inode.

## File unavailable state

If the file is deleted and does not reappear within the retry window, the panel shows a "file unavailable" state with the original path and stays open until the user closes it. It does not reconnect if the file later reappears; close and reopen the panel.

## Performance

Re-reads are dispatched to the main thread and run synchronously, so files over ~100KB can cause brief UI hitches during re-render; split very large documents. The watcher itself runs on a low-priority background queue with negligible CPU impact.
