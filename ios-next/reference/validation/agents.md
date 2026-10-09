# CNAgentUI validation (agent sessions and chat)

Module: `Packages/CmuxNextMobile/Sources/CNAgentUI`. Public roots: `AgentsRoot(connection:)`
(session list, new-session sheet, pushed chat) and `AgentChatView(connection:sessionId:)`
(one session as main content for the drawer shell).

Captured on the remote headless simulator (iPhone 17 Pro, iOS 27 SDK runtime) from the
Drawer scheme with `CMUX_NEXT_DEV_SCREEN=agents` against `CNMockHost`. These debug-only
switches make the captures reproducible: `CMUX_NEXT_AGENT_SESSION=<id>` (push a session),
`CMUX_NEXT_AGENT_EXPAND=1` (open every disclosure), `CMUX_NEXT_AGENT_DRAFT=<text>` (prefill
the composer; `~~` is a newline) and `CMUX_NEXT_AGENT_NEW=1` (open the new-session sheet).
The appearance comes from the launch argument `-cmuxNext.appearance light|dark`.

There is no reference recording for ChatGPT, Claude, Grok, Cursor or T3 Code. Geometry is
checked against the cmux-next Mac agent pane spec
(`plans/cmux-next/spec-proposals/visuals/components/agent-pane.md`) and the iOS patterns
in the task. Motion is checked for continuity: whether anything jumps between consecutive
frames, plus a spring fit from `framediff.py`.

## Evidence

| File | Content |
| --- | --- |
| `agents/screens-light.png`, `agents/screens-dark.png` | Session list; live session with the pinned approval card; error session with an attachment and notices; slash menu; composer at 5 lines; new-session sheet; empty state; model and mode menu |
| `agents/items-light.png`, `agents/items-dark.png` | Every transcript item kind, expanded: user bubble, thought (open), tool rows (search, read, edit with +/− counts, execute with shell block and failed output), tool group summary, plan checklist, assistant markdown (inline code, fenced code with copy, table, bold), inline diffs, Edited N files card, notices, resolved permission, Worked for fold, turn footer |
| `agents/anim-*.png` | Ten evenly spaced frames per animation: send-rise, worked-expand, thought-expand, keyboard-show, composer-grow, card-appear, card-resolve |

Raw recordings and per-frame motion logs (not committed; under `/tmp/nxios/agent/` on the
capture machine): `live.mp4` (send, think, tools, approval, stream, turn end, queue),
`send.mp4`, `disc.mp4`, `kb.mp4`, `grow.mp4`, `perm.mp4`, `queue-*.png`.

## Method for "no jumps"

`framediff.py` is built to compare two sequences, and none exists for these apps, so I
added a continuity check: for each pair of consecutive 60 fps frames, find the vertical
shift (±80 pt) that best aligns the transcript region, plus the fraction of pixels that
changed. Eased motion is a ramp of small shifts. A jump is one large shift between still
frames. `framediff.py` (passing the same input as both ref and impl) supplied a spring fit
per 0.8–1.3 s segment. Simulator recordings are variable frame rate and drop frames under
load (`simctl recordVideo`), so a dropped stretch shows up as a repeated frame followed by
a double step; I judged runs, not single frames.

## Geometry and tokens

| Element | Reference | Measured (impl) | Result |
| --- | --- | --- | --- |
| User bubble | right-aligned, radius 16–18, fill text 5% (cmux-next) | radius 18 continuous, `fillHover` (text 5% light / 6% dark), padding 15×10, max width = column − 48 | pass |
| Assistant reply | full width, no bubble | full-width markdown, 17 pt body (HIG) with 5 pt line spacing; Mac pane is 14 pt (desktop) | pass (intentional iOS size) |
| Code block | language label, copy, horizontal scroll, mono | header 36 pt, label + Copy (checkmark after copy), SF Mono footnote, horizontal scroll, radius 14 (Mac 16) | pass (radius 2 pt smaller) |
| Tool row | glyph + title, mono command, expandable output | SF Symbol per ACP kind, 15 pt title, `Ran \`cmd\`` in SF Mono, chevron when output, diff or command exists | pass |
| Shell output | 12/18 mono, max 240 | SF Mono caption with 3 pt line spacing, max height 220, scrolls both ways, radius 12 | pass |
| Inline diff | +/− on success/danger at low alpha | success 14% / danger 13% backgrounds, sign glyph in color, line numbers, 3 lines of context with gap marker | pass |
| Edited N files card | header with totals, one row per file | "Edited 1 file +10", dim folder + bold name + counts, row opens its diff | pass (no Undo; see gaps) |
| Plan card | checklist | done (struck through, tertiary), in progress (pulsing dotted circle, medium), pending; "3 of 5 done" | pass |
| Approval card | option buttons pinned above composer | Allow once (ink fill), Always, Reject (danger text); the call's command in mono; radius 22, elevated fill; buttons stack when they don't fit | pass |
| Composer | radius 22, field 1→5 lines, `+`, chip, Send in highlight | Liquid Glass `.regular`, radius 22; `+` 36 pt circle; model · mode chip 32 pt tall, radius 16 (Mac 32/16); Send 34 pt circle in `highlight` (Mac 32); Stop square while running with empty field | pass |
| Only hue | highlight only on Send | Send (and dictation active) only; status uses semantic success/danger/attention | pass |
| Nav bar | session title + harness/model subtitle, menu | inline title, `navigationSubtitle("Claude Code · Opus")`, ellipsis menu: Rename, Model, Mode, Copy folder path, Close session | pass |
| Session row | title, preview, harness icon, time, status | harness initial on its group hue, 2-line preview, `harness · cwd`, relative time; running spinner / "Approval" capsule (attention) / error glyph / unread dot | pass |
| Empty state | greeting + composer | harness badge, "Good afternoon. What should Claude Code work on?", folder; the same composer (focus survives the first send) | pass |

## Motion

| Animation | Expectation | Measured | Result |
| --- | --- | --- | --- |
| Message send (bubble insertion + scroll) | bubble appears, prompt rises, no jump | Bubble fades/rises 28 pt on the `appear` spring; transcript rises on the `move` spring (shifts 68, 58, 80, 32, 25, 20, 15, 12, 9 … 1 px/frame, settles in ~20 frames). The reply then grows into the reserved screen: 0 px shift for the whole stream | pass |
| Streaming text ease-in | text eases in per chunk | Revealed length chases the received length on the display clock (≥90 chars/s, backlog drained in ~0.25 s); the last 14 characters ramp in opacity; unclosed `**` or backtick hidden at the edge. Zero-shift pixel change only | pass |
| Growth past the reserve while pinned | follow without snapping | eased scroll to an explicit offset (`.smooth(0.3)`): 3–7 px/frame glides per line instead of 22–32 px snaps | pass |
| New tool rows while live | no jump | rows fade in below the prompt inside the reserve; 0 px shift | pass |
| Turn end | no collapse under the reader | a turn that ends on screen stays unfolded and "Working for" becomes an equal-height open "Worked for"; edited-files card fades in, pinned view glides to it | pass |
| Worked fold expand/collapse | smooth | 24 frames (400 ms), peak 14 px/frame, monotone ramp; framediff fit response 0.5 s, damping 1.0 | pass |
| Thought disclosure expand/collapse | smooth, shimmer while thinking | 22–24 frames, peak 10 px/frame; framediff fit response 0.4–0.55 s, damping 1.0; content fades (an earlier slide-from-top variant overlapped the label and was replaced) | pass |
| Composer growth (1→5 lines) | smooth | glass box height follows a measured twin field on the `move` spring; the transcript follows with an eased scroll; max 5 px/frame, no flags (before: 16–24 px in one frame) | pass |
| Approval card appear | smooth, no reflow jump | card slides up on the `move` spring; transcript glides 2–8 px/frame (before the fix: content height fell by 333 pt in one frame) | pass |
| Approval card resolve | smooth | card leaves (move + opacity); transcript eases down: −23, −19, −19, −22, −8 … −1 px/frame over ~40 frames | pass |
| Keyboard show | transcript and composer track the keyboard | 14, 31, 37, 37, 34, 29, 24, 20, 16, 12 … 0 px/frame (eased, monotone); framediff fit response 0.4 s, damping 1.0 | pass |
| Keyboard hide (interactive drag) | tracks the finger | constant 54 px per captured frame during the drag (finger speed at 20 fps capture), then −19, −4 settle | pass |
| 60 fps | — | Content motion is spring- or display-link driven; the headless simulator recorder captures 20–60 fps, so frame pacing could not be measured. See gaps | not measured |

## Behaviour checks

| Check | Result |
| --- | --- |
| Hardware Return sends; Shift-Return keeps the newline | Return sends (axe HID key 40); Shift-Return not exercised |
| Sending while a turn runs queues; the queue sends when the turn ends | pass (`queue-light.png`, `queue-after-light.png`) |
| Composer keeps focus after send | pass (refocused after the row insertion) |
| Host echo replaces the local bubble regardless of arrival order | pass (an earlier version showed a duplicate bubble when the echo followed the RPC response) |
| Stop (agent.cancel) while running | Stop button wired; mock writes "Turn cancelled" (not recorded) |
| Slash menu from `commands` on `/` | pass |
| Model/mode chip → agent.setModel / agent.setMode | menu verified; selection updates optimistically |
| Reconnect reload on `connection.generation` | wired via `.task(id:)`; not exercised with `MockHost.dropAllLinks` |

## Gaps

- No reference video exists for the AI apps, so the motion values are self-consistency checks, not ref-vs-impl fits. The springs fitted by framediff are rough (RMSE 0.06–0.22) because each segment mixes motion with streaming text.
- Frame pacing at 60 fps is unverified: simulator recordings drop frames. An Instruments hitch trace on a device is the next step.
- Dictation is implemented (on-device SFSpeechRecognizer) but hidden. The app Info.plist (shell-owned) lacks `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`, so the composer shows Send instead of the mic. It is untested.
- Camera and file attachments are wired, but only the photo picker path was reached. Attachment thumbnails in bubbles show names, not images (transcript items carry no data).
- No syntax highlighting in code blocks or diffs. The Mac pane colors code from the theme's ANSI palette.
- The Edited files card has no Undo or "View changes" (the Mac pane's host revert has no protocol method yet).
- Very long transcripts (over 160 rows) switch to a `LazyVStack` without the turn reserve, so the send-rise behaviour there is unvalidated.
- The ScrollView's `scrollTo(edge:)` is not used for repeated corrections: re-setting the same edge position is ignored. The code scrolls to explicit offsets instead (documented in source).
- Builds in the agent slot need a one-time app uninstall after the shell's switch to a UIKit scene delegate; otherwise the window restores black.
