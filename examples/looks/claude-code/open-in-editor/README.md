# Open file citations in your editor

In a local agent chat, click a citation such as `src/main.rs:42` to open the real file at line 42. Numbered search matches and read results use the same action. The click runs `file.open {where: editor}`, which opens the app the `files.textEditor` setting names (**Text Editor** in cmux Settings: an app name, bundle ID or `.app` path). When the setting is empty or names an app that is not installed, the system's app for source code opens it instead. Set it to VS Code, Cursor, Windsurf, or Zed to land on the cited line; any other editor opens the file at its usual position. `files.textEditor` is yours to change: run `cmux settings get files.textEditor` to see it.

From the repository root, preview and apply this profile:

```sh
cmux customize use ./examples/looks/claude-code/open-in-editor/profile.json
cmux customize check
cmux customize apply
```

To try it from this checkout, click `examples/looks/claude-code/open-in-editor/profile.json:6` in a local chat. Line 6 enables the setting. To undo the applied profile, run `cmux customize rollback`.
