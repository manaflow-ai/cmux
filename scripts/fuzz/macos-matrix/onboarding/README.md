# Onboarding end to end (scoreboard rows ON1 and ON2)

Leo, 2026-11-05: "we're going to have the onboarding flows that say like the ChatGPT and Claude Code
desktop apps have for like enabling the things, and we're just going to use it end to end. All right,
like we click around the menus and have the things go."

**ON1** passes when, on a fresh macOS VM, a NIGHTLY installed from its DMG gets Computer Use and Screen
Sharing turned on only through cmux's own cards, palette, Settings and the System Settings prompts it
opens, and an agent then clicks, types and drags in a background app. No terminal command and no
relaunch are allowed. **ON2** passes when an iPhone pairs with that Mac and shows its screen within 10 s of
the tap, with no setting touched.

`--suite onboarding` of the macOS matrix is the ON1 check:

```bash
scripts/cmux-next/os-matrix.sh --nightly newest --os 26 --suite onboarding
```

`onboarding.py` plays the person over VNC only, as real keyboard and pointer events, and sees only VNC
frames read with OCR (`vmeye.swift`, Apple Vision, compiled on the Tart host and never copied into the
guest). SSH is for the harness's own part: it puts the DMG in Downloads with a browser's quarantine,
registers the scripted agent's harness, starts the agent's turn and reads the results. It never turns
anything on. `agent.py` is the agent. It is an ACP agent with no model, so a run passes or fails on cmux
and not on a model. It reaches the cmux Computer Use helper through the `cmux-cua` MCP server that acpmux
gives every agent session.

Each run writes `result.json` with each step's verdict, the person's actions, its seconds and the
findings, plus a still per step (`shot-<step>.png`) and `onboarding.mp4` of the whole run.

## The reference flow

The reference comes from Claude Desktop, the Claude Code CLI and Codex / ChatGPT computer use (studied
2026-11-05; sources in cmuxterm-hq#7146). The best of them, put together, works like this:

1. **Entry: 1 action.** A card shows in the chat the first time an agent needs the computer, and the same
   card is in Settings. One click both turns computer use on and starts setup.
2. **A signed helper holds the grants.** Both grants go to a helper with a stable identity at an
   unversioned path, and the helper does all capture and input. So the main app never needs Screen
   Recording and never gets "Quit & Reopen" (Codex: "Codex Computer Use.app").
3. **Each grant: 3 actions.** These are Allow, a drag of the helper into the list, and Touch ID or the
   password.
   - Allow opens the exact pane (`x-apple.systempreferences:com.apple.preference.security?Privacy_…`).
   - A panel docked to System Settings holds the helper to drag. Codex's binary has
     `SystemSettingsAccessoryWindow`, `DraggableApplicationView` and `ArrowWindow`.
   - There are no `AXIsProcessTrustedWithOptions(prompt:)` or `CGRequestScreenCaptureAccess` prompts
     competing with the panel.
4. **The app continues by itself.** It polls the grant while the panel shows. For Screen Recording it
   uses a ScreenCaptureKit probe or a fresh process, never `CGPreflightScreenCaptureAccess`, which keeps
   its first answer for the life of the process. Only the helper is ever relaunched, never the app.
5. **Per app: 1 action.** Allow once or Always allow.

That is **7 actions to ready**, plus 1 per new app and about 1 a month for macOS 15+'s private window
picker consent.

| App | Entry | Accessibility | Screen Recording | Relaunch | Per app | To the first click |
|---|---|---|---|---|---|---|
| Claude Desktop | 2–3 (Settings toggle) | 3, or 6–7 when not listed | 3, or 6–7 | 1 | 1 | about 10–11 |
| Claude Code CLI | 2 plus "Try again" | 3, or 6–7 | 3, or 6–7 | 1–2 | 1 | about 11–13 |
| Codex / ChatGPT computer use | 2–3 | 3 | 3 | 0 | 1 | about 9–11 |
| Reference | 1 | 3 | 3 | 0 | 1 | **8** |

## cmux NEXT today, step by step (feat-cmux-next f5f0e816, 2026-11-05)

Counts are from the code; the check measures them on each NIGHTLY.

### Computer Use

| # | What the person does | Actions | Reference | Note |
|---|---|---|---|---|
| 1 | Starts setup. From the palette: Cmd-Shift-P, "Computer Use Setup", Return. From a chat: Continue on "Allow computer use?". From Settings: "Set Up…" | 1 (chat, Settings) or 3 (palette) | 1 | The chat card is a floating panel at the top of the screen, not in the chat. |
| 2 | Clicks Allow on Accessibility. cmux turns Computer Use on, opens the Accessibility list and docks the drag panel | 1 | 1 | No native prompt (#26123). |
| 3 | Drags "cmux Computer Use" into the list, then the password | 2 | 2 | Detected through the `com.apple.accessibility.api` notification; the window comes back by itself. |
| 4 | Clicks Allow on Screenshots | 1 | 1 | The helper calls `CGRequestScreenCaptureAccess`: a native prompt opens beside the drag panel. |
| 5 | Answers that prompt ("Open System Settings") | 1 | **0** | Finding F1: the reference raises no second UI. |
| 6 | Drags the helper into the Screen & System Audio Recording list, then the password | 2 | 2 | |
| 7 | "Quit & Reopen" for the helper, when macOS shows it | 0–1 | **0** | Finding F2: it applies to the helper, not cmux. |
| 8 | Waits for the window to come back | 0, or a click back into cmux | 0 | Finding F3: nothing reads the Screen Recording grant while System Settings is in front. No notification exists for it, and the drop's recheck runs before the password lands. The window comes back only when the helper restarts or cmux is activated again. |
| 9 | Allows macOS 26's private window picker alert | 1 | about monthly | |
| 10 | Clicks Done on "Computer Use is ready." | 1 | **0** | Finding F4: the reference closes by itself. |
| | **Total to ready** | **about 10–12** | **7** | |

### Screen Sharing (this Mac to the iPhone)

| # | What the person does | Actions | Note |
|---|---|---|---|
| 1 | Signs in to cmux (the account the phone uses too) | 3 or more, plus the account flow | Finding F5: a fresh install cannot share until it is signed in. |
| 2 | Settings → Devices, or the palette's "Screen Sharing" | 2 | |
| 3 | Turns on "Allow Mac Screen on this Mac": `CGRequestScreenCaptureAccess` for **cmux itself** | 1 | |
| 4 | Grants Screen Recording to cmux, then **Quit & Reopen cmux** | 2–3 | Finding F6: a relaunch of cmux itself, which ON1 forbids. The grant goes to cmux.app, not to the signed helper. |
| 5 | "Open System Settings" on the Accessibility row, then turns cmux on (no drag panel) | 2–3 | Finding F7: none of Computer Use's guidance (drag panel, comeback). |
| 6 | Allows the phone on the Mac's approval panel | 1 | ON2: the phone's pairing code skips it once. |
| | **Total** | **about 11–13, with a relaunch** | The reference shares through the same helper that holds the Computer Use grants: 0 more grants. |

Copy: the iPhone asks to "turn on Share This Mac in its Settings › Devices", but the Mac's toggle is
"Allow Mac Screen on this Mac" (finding F8).

## Findings and owners

| ID | Finding | Owner |
|---|---|---|
| F1 | Allow on Screenshots raises the native Screen Recording prompt beside the drag panel (1 extra action, two UIs at once) | consent card and prompts (Leo's #26123, #30419); fixed only once ON1 measures it |
| F2 | Quit & Reopen for the helper on the Screen Recording grant | the signed helper (cmux#28584, Aziz) |
| F3 | No read of the Screen Recording grant while System Settings is in front; the window can wait until cmux is clicked again | Computer Use setup window (#26065); fixed once ON1 measures it |
| F4 | Done on the ready window | Computer Use setup window (#26065) |
| F5 | Screen Sharing needs a signed-in account first | Screen Sharing (Aziz); ON1 needs a test account in the VM |
| F6 | Screen Sharing grants Screen Recording to cmux.app: Quit & Reopen relaunches cmux | the signed helper (cmux#28584, Aziz) |
| F7 | Screen Sharing's grants have no drag panel and no comeback | Screen Sharing (Aziz) |
| F8 | "Share This Mac" on the iPhone, "Allow Mac Screen on this Mac" on the Mac | Screen Sharing (Aziz) |
