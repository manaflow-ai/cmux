# The Codex app look: parts

Reference: the Codex desktop app, light (a full-window screenshot of a finished thread). One row per
part. `matched`: looks and works as the reference. `close`: there, with a named difference. `gap`:
missing, with the capability it needs and where it would go.

| Part | State | Notes |
|---|---|---|
| Sidebar surface | matched | Theme file: `#d9d9d9` at 92% (translucent), separate from the white page, no borders. |
| Sidebar header rows (New thread, Automations, Skills) | close | The "Threads" views section (`customize/main.js`) draws them as sidebar rows; they run `new.agentChat`, `automations.show` and `appStore.show` (Skills has no own page in cmux, so it opens the app store). Not yet tried in a running app. |
| New-chat button | close | The section's "New thread" row; cmux's own sidebar new-workspace button also stays. |
| "Threads" header | close | A caption in the section; the reference's header buttons (new folder, filter) are not drawn. |
| Project folders | matched | `sidebar.groupBy: folder` and the section's folder rows. |
| Chat rows: title and time | matched | `sidebar.showTimestamps` and the section's rows ("2h", "18h", "1d"). |
| Chat rows: branch | gap: the reference shows none in rows; nothing to do | Counted as gap only so the row is honest: no branch column exists in either. |
| Selected row | close | Native selected wash; the reference's is a slightly darker rounded gray. Sidebar row fills are native (Swift), not in a look branch. |
| Account row ("Personal") | gap: no account row in the cmux sidebar | Needs a native sidebar footer row with the signed-in account (Swift sidebar, a cmux PR). `accounts.show` exists as an action. |
| Chat title bar (title, project in gray, "…") | close | `ThreadTitle.tsx` adds the project after the title in gray; cmux's own header tools (list, inbox, terminal, browser, "…") stay on the right where the reference has Run, Open and Commit. |
| User prompt | matched | Right-aligned `#f2f2f2` pill, 20 px corners, no rim (`codexLook.css`). |
| Assistant text | matched | Plain text, no bubble, the system font at 15 px. |
| Inline code | matched | Light gray `#f0f0f0` chips, 6 px corners. |
| Links | matched | Blue `#0a74e8`, no underline until hovered. |
| Code blocks | close | cmux's light gray card with the language and copy button; the reference shows none in its screenshot. |
| Tool rows | close | cmux's tool rows in the muted text; not shown in the reference. |
| Thinking / "Worked for" | close | cmux's "Worked for 1m 16s ›" fold; the reference collapses its work into the paragraphs. |
| Scroll-to-bottom button | matched | White 36 px disc, gray hairline, soft shadow, arrow in the text color, centered over the composer. |
| Composer box | matched | White, 24 px corners, a hairline and a soft shadow (chat and New Tab). |
| Placeholder | matched | "Ask for follow-up changes" (chat); "Ask anything, @ to add files, / for commands" (New Tab). |
| Attach button | matched | "+" at the lower left inside the box. |
| Model picker | close | Inside the box right after "+", as the reference's "Custom Medium ⌄"; it shows the model's mark and name. |
| Effort | close | Shown next to the model when the agent has one; the reference writes it in gray inside the same pill. |
| Send button | matched | Dark round button with a white ↑, gray while empty; mic just before it. |
| Row below the composer ("Local ⌄", branch) | close | In a chat, Codex's look keeps cmux's folder and computer tray tucked over the box; on New Tab the folder and computer strip moves under the box. The branch on the right is not drawn: needs the chat's git branch in the composer strip (web, ComposerContext). |
| Empty chat | close | Same as New Tab below. |
| New Tab page | close | "Let's build" over the white composer, the strip under it. The mode and model sit under the box (New Tab's own composer keeps cmux's quiet row) rather than inside it. |
| Settings page | gap: not restyled | The Settings page takes the theme's colors; its layout is cmux's. A Codex-style settings layout would be a separate web change (`webviews/src/pages/settings`). |

Counts: matched 12, close 13, gap 3.
