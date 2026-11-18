# Parts: Claude Code desktop (dark)

Reference: the Claude Code desktop redesign (three panes, session sidebar collapsed), plus the
redesign's text for the sidebar. `matched` = drawn the same way; `close` = same parts, small
differences; `gap: <why>` = a missing capability and where it would go.

| Part | State | Notes |
|---|---|---|
| Sidebar header | close | Native chrome: the profile's darker sidebar surface and quiet section look; no web layer reaches it. |
| New-chat button | close | cmux's own new-chat button in the sidebar header; same place, cmux's glyph. |
| Project folders | matched | `sidebar.groupBy: folder`, and the Sessions section groups by project. |
| Session filters (status, project, environment) | matched | Sessions section (look/customize): three menus over the list; group by project or not. |
| Chat rows (title, time, branch) | close | Title and age in Sessions and the native rows (`sidebar.showTimestamps`); no branch on the row. |
| Selected row | close | The views kit's `selected` fill; the app's is a lighter warm grey. |
| Account row | gap: native sidebar footer; a theme cannot restyle it (Swift, a cmux PR). |
| Chat title bar ("project / chat title") | gap: the title bar is native Swift (window chrome); needs a "project / title" title format setting. |
| User prompt (right-aligned dark pill) | matched | Right-aligned, 9% warm fill, 12 px radius. |
| Assistant text | matched | System font 14 px on the warm page, full ink. |
| Inline code | matched | Mono on the warm grey (`--cv-code-bg`). |
| Code blocks | close | Warm grey block; cmux's header and copy controls. |
| Tool rows (Edit/Write + file chip + counts + chevron) | matched | Bold verb, path from the chat's folder in a mono chip, +N / -N, chevron; one line; no icons. |
| "Updated todos N items", "Typecheck ›" collapsibles | close | Rows of plain words with a chevron, full ink; the todo row keeps cmux's wording. |
| Live line (orange asterisk, "2m 14s · ↓18.6k tokens") | close | Clay ✻ turning before the line; cmux's words lead it ("Running…"), then the time and tokens. |
| Thinking / "Worked for" | close | cmux's fold, same quiet line. |
| Scroll-to-bottom button | close | cmux's own. |
| Branch bar ("main ← claude/branch +N -N Create PR") | close | Over the composer; the base is always "main" (no base branch reaches the pane: gap for other bases, acpmux summary). |
| Composer box | matched | Dark rounded box (14 px), warm fill, hairline edge. |
| Placeholder "Type / for commands" | matched | cmux's own placeholder already reads this. |
| Attach button ("+") | matched | Under the box in Claude's look. |
| Mode ("Auto accept edits") | close | The mode picker under the box names the harness's mode ("Accept edits"). |
| Terminal icon | close | cmux's shell toggle sits in the box's row. |
| Mic | matched | Dictation mic in the row. |
| Model picker with spinner | close | Model name at the right; the context ring stands where the spinner is. |
| Effort | close | cmux's effort picker beside the model (the reference shows none). |
| Send button | close | Claude's plain glyph (Claude's composer look). |
| Empty chat | close | Claude Code desktop's new-session page (the Default template). |
| New Tab page | close | Default template: the composer at the foot, environment and suggested actions centred over it. |
| Settings page | gap: the Settings page takes the theme's colours, but its layout is cmux's; no reference of the app's settings was given. |
