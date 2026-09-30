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

## PR media

Every push to a same-repository app pull request (the ones that get a dogfood
build link; docs or web only changes don't) gets screenshots and a GIF of its
build, with no setup. `.github/workflows/pr-media.yml` starts when the PR's CI
run completes and runs beside CI, never in its verdict:

1. It picks up to two tours whose `paths` globs match the changed files, or
   `sidebar-and-chrome-tour` when none match. A line in the PR description
   overrides the pick on the next push: `Dogfood-tours: browser-notifications-tour, right-sidebar-and-menus-tour`,
   or `Dogfood-tours: none` to turn it off.
2. Each tour runs on the app and UI test bundle the PR's own CI compiled
   (`run-e2e.sh --adopt-only`), on the runner pool that compiled it, or on
   main's build of the same inputs when CI reused it (`--adopt-main`). Media
   never compiles on its own: when no build loads on the UI test Macs (CI
   compiled on a pool they cannot load, its compile failed, or main's build
   is gone), the tour is skipped. Every picked tour gets a line in the
   section: its media, or `skipped:` and why.
   `gh workflow run pr-media.yml --repo manaflow-ai/cmux -f pr=<n> -f allow_compile=true`
   compiles one for a PR that needs media anyway.
3. The frames become a few key PNGs and a captioned GIF, uploaded to the
   `pr-media` branch at `<pr>/<sha8>/<tour>/` and shown in a media section of
   the PR's sticky dogfood comment (posted by the media job when the PR has
   no `dev-build` label), each labelled with its tour and SHA. A new
   push replaces the section; tours of a head that already has media are not
   run again (`-f force=true` reruns them).

**Before merging a PR, read its media.** Check the section's SHA is the head
you are merging, then look at every key frame and the GIF critically: does the
changed UI appear, and does it look right in each state the tour reaches? A
passing tour only means no step failed; a frame that shows a blank window, the
wrong screen, a system dialog over the app or the old behavior is a finding.
Open the run link for all frames and the accessibility trees. When no tour
reaches the change, add or extend one (with `paths` for the files it covers)
in the same PR, and the next push shows it. A push that changes no app
input (only a tour, docs or tests) runs the tours on the app CI already built
for the same inputs earlier in the PR, and the section says which build. A PR
whose CI reused main's build tours main's build. For evidence no tour can produce
(a drag, a recording from a fleet dogfood), upload it with `scripts/pr-media.py`;
the workflow uploads through the same tool.

`pr-media-prune.yml` keeps the branch small: weekly it drops the folders of
pull requests closed over 30 days ago (unless an upload touched them since)
and squashes the branch to one commit, so images in those old comments stop
loading. It is a dry run unless dispatched with `-f apply=true` or
`CI_PR_MEDIA_PRUNE_APPLY` is 1.

Give a new tour a `paths` list of `fnmatch` globs (`*` crosses directories),
for example `"paths": ["Sources/*Browser*", "Packages/macOS/CmuxBrowser/*"]`.
Without one, only a `Dogfood-tours:` line or an edit to the tour file picks it.
The test reads only `steps` and `launch`, so `paths` changes nothing about a run.

## Write a tour

A tour is a steps array, or an object with `steps`, an optional `launch`, and
the `paths` globs [PR media](#pr-media) picks it by:

```json
{
  "paths": ["Sources/*Sidebar*"],
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
| `{"dragAt": {"from": {"x": 0.2, "y": 0.5}, "to": {"x": 0.1, "y": 0.5}, "duration": 0.2}}` | Presses at `from` and drags to `to`, in the same window space. Use it for resizers and other drag handles. |
| `{"menu": ["File", "New Workspace"]}` | Clicks through the menu bar. Each element after the first names a direct child of the menu the one before it opened, so a submenu item needs its submenu in the path (`["File", "Workspace", "Rename Workspace…"]`). Titles repeat across menus and at different depths inside one menu, and only the full path tells them apart. |
| `{"socket": "method", "params": {...}, "save": "name"}` | A v2 control socket request. The reply is attached; `save` keeps its `result`, and a later param `"${name.workspace_id}"` reads a field from it. |
| `{"socketLine": "agent_journal_append {...}"}` | One raw v1 socket line, for verbs with no v2 method. Every `${name.path}` inside it is replaced with a saved value; numeric path parts index arrays (`${ws.surfaces.0.id}`). A reply starting with `ERROR` fails the step. |
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
