# Parts: Claude Code desktop (dark)

Reference: the Claude Code desktop redesign (three panes, session sidebar collapsed), plus the
redesign's text for the sidebar. `matched` = drawn the same way; `close` = same parts, small
differences; `gap: <why>` = a missing capability and where it would go.
Captures (`captures/`): the mock pane on Linux under the look's theme (`webviews/scripts/agent-pane/look-capture.mjs`).
The real-app capture (native sidebar and title bar) is pending; see HANDOFF.md.

**Count: 13 matched, 15 close, 4 gap.**

| Part | State | Notes |
|---|---|---|
| Sidebar header | close | Native chrome: the profile's darker sidebar surface and quiet section look; no web layer reaches it. |
| New-chat button | close | cmux's own new-chat button in the sidebar header; same place, cmux's glyph. |
| Project folders | matched | `sidebar.groupBy: folder`, and the Sessions section groups by project. |
| Session filters (status, project, environment) | matched | Sessions section (`look/customize`): three menus over the list, and group by project or not. Not yet seen in a real-app capture. |
| Chat rows (title, time, branch) | close | Title and age in Sessions and the native rows (`sidebar.showTimestamps`); no branch on the row. |
| Selected row | close | The views kit's `selected` fill; the app's is a lighter warm grey. |
| Account row | gap: native sidebar footer; a theme can't restyle it (Swift, a cmux PR). |
| Chat title bar ("project / chat title") | gap: the pane's header shows the chat title alone (`header/`); "project / title" needs the project name in the header's model, and the window title bar is native Swift. |
| User prompt (right-aligned dark pill) | matched | Right-aligned, warm 9% fill, 12 px radius. |
| Assistant text | matched | System font on the warm page, full ink. |
| Inline code | matched | Mono on the warm grey. |
| Code blocks | close | Warm grey block; cmux's header and copy controls. |
| Tool rows (Edit/Write + file chip + counts + chevron) | matched | Bold verb, the path in a mono chip (relative to the chat's folder, else its last three parts), +N / -N, chevron; one line per file; no icons. |
| "Updated todos N items", "Typecheck ›" collapsibles | close | Commands are one muted line with a chevron ("Ran tests with bun ›"); the todo list keeps cmux's plan card, not a one-line "Updated todos N items". |
| Live line (orange asterisk, "2m 14s · ↓18.6k tokens") | close | A clay ✻ that turns (motion-gated) leads cmux's live line, then the time and tokens. The mock turn ends too fast to catch it in a capture. |
| Thinking / "Worked for" | close | cmux's "Worked for Ns ›" fold holds the commands; the edits stay listed at the turn's end. The app lists every call inline. |
| Scroll-to-bottom button | close | cmux's own. |
| Branch bar ("main ← claude/branch +N -N Create PR") | close | Over the composer: base ← branch, Create PR (asks the agent). The +N -N counts show only for edits in the composer's loaded rows, and the base is always "main" (gap for other bases: the acpmux summary has no base branch). |
| Composer box | matched | Dark rounded box (14 px), warm fill, hairline edge. |
| Placeholder "Type / for commands" | matched | cmux's own placeholder already reads this. |
| Attach button ("+") | matched | Leads the box in Claude's composer look. |
| Mode ("Auto accept edits") | close | The mode picker under the box names the harness's mode ("Bypass permissions", "Accept edits"). |
| Terminal icon | gap: Claude's composer look has no terminal toggle under the box; cmux's shell lives in the box's `!` prefix. |
| Mic | matched | Dictation mic in the box. |
| Model picker with spinner | close | The model name with its clay mark at the right, and the context ring where the app's spinner is. |
| Effort | close | cmux names the effort after the model ("Opus 5.5 Medium"); the reference shows none. |
| Send button | matched | Claude's look: the plain glyph, shown once there is text. |
| Empty chat | close | Claude Code desktop's new-session page (the Default template). |
| New Tab page | close | Default template: recent folders and chats in cards over the composer, the composer at the foot. |
| Settings page | gap: takes the theme's colours, but its layout is cmux's; no reference of the app's settings was given. |
| Warm palette and clay accent | matched | `files/theme.json`: `#1f1e1c` page, `#181816` sidebar, `#d97757` accent, no borders. |
| Edited-files card | matched | Hidden (`agentPane.editedFiles.show: never`): the app shows the per-file rows instead. |
