# Native chrome for computer-use agents (accessibility identifiers)

Status: landed on feat-cmux-next (agent interop, 2026-10-19). Audit:
`agent-interop` proof `audit/ACCESSIBILITY.md`. React pages follow
[a11y-foundation.md](a11y-foundation.md) instead.

## Contract

An agent that reads the macOS accessibility tree (OpenAI computer use,
cmux-cua, any `AXUIElement` client) must find and press every native control
without matching English text:

- Every pressable element (button, menu button, tab, disclosure, checkbox,
  splitter, slider) has a localized label (`AXDescription` or `AXTitle`) and a
  stable `AXIdentifier` of the form `cmux.<area>.<control>`. When an area has
  many of one control, the model id follows: `cmux.tabs.tab.<tabID>`,
  `cmux.sidebar.group.<groupID>.add`, `cmux.sidebar.workspace.<id>.close`.
- A control drawn in layers is an `NSAccessibilityElement` with its own role,
  label, identifier and `accessibilityPerformPress` (the tab's x:
  `TabCloseAccessibilityElement`). A custom action alone is not enough.
- A decorative image next to a labeled row is not an element
  (`setAccessibilityElement(false)`).
- Menu bar items from the action registry carry `cmux.action.<actionID>`.

Identifiers are API: renaming one breaks agent scripts and the tour. Add new
ones; do not reuse an old one for another control.

## Tests

- `AgentInteropAccessibilityTests` (CmuxNextAppTests) hosts the tab strip, pane
  toolbar, titlebar band, sidebar, spaces strip, group header actions and
  dividers in a window and walks the in-process tree with `AccessibilityAudit`.
  A new chrome control without a label or an identifier fails it.
- Fleet: `cmux-ci run --class light --script scripts/ci/package-test-lane.sh
  --ref SHA --arg=suite --arg=Packages/macOS/CmuxNext
  --arg=AgentInteropAccessibilityTests --label suites`.

## Computer-use tour

`scripts/cmux-next/ax-tour.sh` drives a tagged DEV app only through AX reads,
AXPress and window screenshots: new workspace, new tab, split pane, switch
tab, command palette open and close, Settings (a page tab) open and close,
then closes the split, the tab and the workspace it made. Each step is judged
by its result in the AX tree (a non-success AXPress code goes into the step's
detail) and writes `manifest.json` and `shots/NN-step.png`.

```bash
./scripts/reload.sh --tag ax-tour --launch          # or a fleet build of the tag
scripts/cmux-next/ax-tour.sh --tag ax-tour --out /tmp/ax-tour
scripts/cmux-next/ax-tour.sh --tag ax-tour --dump   # print the AX tree and menu ids, act on nothing
# GUI build host, a pushed SHA (the host launches and stops the app):
nx-remote --needs gui --app-from-fleet cmux --tag TAG --ref SHA -- \
  'open -n --env ACPMUX_AGENT_LAUNCH=deny --env NX_REMOTE=1 "$NX_APP"; sleep 10;
   scripts/cmux-next/ax-tour.sh --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS/ax-tour";
   rc=$?; "$NX_APP_STOP"; exit $rc'
```

It refuses every bundle id but `com.cmuxterm.app.debug.<tag>` before it reads
anything, never activates an app, never posts mouse or key events, and with
`--app` (local use) quits only the PID it launched. The host needs the
Accessibility grant. Screenshots use ScreenCaptureKit, or the host's
`$NX_CAPTURE` helper when it is set (the job process has no Screen Recording
grant); without either the steps still run and the manifest records the
screenshot problem.
