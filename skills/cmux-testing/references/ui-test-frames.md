# See what a UI test did

```bash
scripts/ui-test SidebarHelpMenuUITests          # run it in CI at your pushed HEAD, then show its steps
scripts/ui-test <run id or URL>                 # show a finished run's steps
```

It prints each test's result, its failure, the action it failed at, and paths to:

- `steps.md`: the test as numbered actions ("Click "SidebarHelpMenuOptionSettings" MenuItem"), with the failing one marked.
- `frames/NN-<action>.jpg`: the screen right after each action. Open the failing one first.
- `sheet-N.jpg`: 3x4 contact sheets of the frames, tile N being step N.

CI builds these for every UI run: the action lists are in the run's job summary, and the frames in its `ui-frames` artifact, which `scripts/ui-test` downloads.

Keep in mind:

- XCUITest keeps screenshots only for failing tests. To see a passing test, attach a capture with `lifetime = .keepAlways`; it shows as `capture: <name>`.
- **Expected Failure** is not a pass. It usually means the harness absorbed a launch or activation failure and the test ended before the behavior under test.
- Hosts that record a failing test's screen instead of screenshots give one frame a second, captioned with the running action.
- If a frame shows a system dialog over the app, that explains focus and activation failures. The E2E action closes leftover dialogs before tests run.
