# Dogfood the app from CI

Use this to look at cmux the way a user would: open workspaces, split, hover,
open the palette and Settings, and get a screenshot and accessibility tree of
every moment you ask for. You write a JSON tour; CI runs it against the built
app on a macOS runner with a display. Nothing runs on your Mac.

A tour is read at run time, so tours of a commit CI already built compile
nothing. Iterate on the tour, not on Swift.

## Run a tour

```bash
scripts/run-e2e.sh --scenario dogfood/scenarios/sidebar-and-chrome-tour.json --ref <pushed-sha> --frames
```

- `--frames` waits for the run, then writes the screenshots, contact sheets, and
  text files under `$TMPDIR/cmux-ui-frames/<run>/DogfoodScenarioUITests/testRunScenario/`
  ([UI test frames](ui-test-frames.md)): each `shot` is a frame, and trees,
  socket replies and `steps.log` are in `attachments/`. Open the contact sheets first,
  then single frames.
- The commit must contain `cmuxUITests/DogfoodScenarioUITests.swift` (any commit
  on or after the one that added it).
- Tours of one commit run side by side; each dispatch gets its own concurrency
  group.
- An `Expected Failure` with 0 frames means the runner could not bring the app
  to the foreground, and XCUITest ended the test inside `launch()`. It happens
  on some Blacksmith runners; dispatch the tour again.

## Write a tour

A tour is a steps array, or an object with `steps` and an optional `launch`:

```json
{
  "launch": {"env": {"KEY": "value"}, "args": ["-someDefault", "YES"], "language": "ja", "locale": "ja_JP", "zoom": true},
  "steps": [
    {"socket": "workspace.create", "params": {"title": "Build", "focus": true}, "save": "build"},
    {"shot": "after-create"}
  ]
}
```

| Step | Does |
| --- | --- |
| `{"shot": "name"}` | Screenshot of the app's front window, kept even when the tour passes. Add `"screen": true` for the whole display. |
| `{"tree": "name"}` | The app's accessibility tree as text. Use it to find identifiers to click. |
| `{"wait": 0.5}` | Seconds to let animations and renders settle. |
| `{"key": "d", "modifiers": ["command", "shift"]}` | A key press. Names: `return`, `escape`, `tab`, `delete`, `space`, `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`, or one character. |
| `{"type": "echo hi\n"}` | Types text into the focused view. |
| `{"click": target}`, `doubleClick`, `rightClick`, `hover` | Acts on an element. All four also take `"modifiers"`. |
| `{"clickAt": {"x": 0.1, "y": 0.2}}`, `hoverAt` | Acts on a point in the main window, 0 to 1 from the top left. Both also take `"modifiers"`. |
| `{"clickAt": {"x": 0.5, "y": 0.4}, "modifiers": ["command"]}` | A cmd-click. Same modifier names as `key`. Needed for anything behind cmd-click, such as opening a link in terminal output. The modifiers are held as global keyboard state around the click, so a cmd-`hover` works the same way for hover affordances. |
| `{"menu": ["File", "New Workspace"]}` | Clicks through the menu bar. |
| `{"socket": "method", "params": {...}, "save": "name"}` | A v2 control socket request. The reply is attached; `save` keeps its `result`, and a later param `"${name.workspace_id}"` reads a field from it. |
| `{"expect": target, "exists": false}` | Checks that an element exists (or not). |

A target is an accessibility identifier string, or an object with `id`,
`label`, or `labelContains`, plus optional `type` (`button`, `textField`,
`staticText`, `menuItem`, `checkBox`, `image`, `group`, `cell`, `tab`, `window`,
`popover`) and `index`.

The window is zoomed to fill the display at launch (`"zoom": false` keeps the
default size). Every tour starts with `00-launched` and ends with `99-final` plus
a whole-display `99-final-screen`, which shows anything the CI desktop put over
the app. A step that fails is recorded, followed by a `NN-failed` screenshot, and the
tour carries on. The test fails at the end and lists every failed step; `steps.log`
has the full sequence.

## Tips

- Start a tour for a new area with a `tree` step, read it, then write the clicks.
  Socket and CLI methods are listed in `Sources/TerminalController+DebugMethodNames.swift`
  and the `cmux` skill.
- Default shortcuts: new workspace ⌘N, split right ⌘D, split down ⇧⌘D, command
  palette ⇧⌘P, toggle sidebar ⌘B, Settings ⌘,. Read `KeyboardShortcutSettings.swift`
  for the rest.
- Give `workspace.create` shell text as `initial_input` (`"echo hi\n"`).
  `initial_command` replaces the shell, so a command that exits within
  Ghostty's 250 ms threshold shows the red "failed to launch" screen.
- Add `{"wait": 0.5}` before a `shot` after anything animated; hover reveals fade
  in over about 120 ms.
- Keep reusable tours in `dogfood/scenarios/`. A tour is a look, not a test: when
  it finds a bug, fix it and add a focused test for the behavior.
