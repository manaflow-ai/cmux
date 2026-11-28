# Command Reference (cmux Markdown)

```bash
cmux markdown open <path>
cmux markdown <path>          # shorthand, "open" is implicit
cmux markdown --help
```

| Flag | Description | Default |
|------|-------------|---------|
| `--workspace <id\|ref\|index>` | Target workspace | `$CMUX_WORKSPACE_ID` |
| `--surface <id\|ref\|index>` | Source surface to split from | Focused surface |
| `--window <id\|ref>` | Target window | Current window |

## Output

```
OK surface=surface:8 pane=pane:3 path=/absolute/path/to/file.md
```

`--json` returns `window_id`, `workspace_id`, `pane_id`, `surface_id`, and `path`.

## Panel behavior

The panel opens as a horizontal split to the right of the source surface. The tab shows the filename and a document icon; the file path appears as a breadcrumb at the top. Content is read-only with text selection enabled.

Markdown panels are saved and restored across sessions and re-read the file from disk on restore. A panel is not recreated if the file no longer exists at restore time.

See also [live-reload.md](live-reload.md).
