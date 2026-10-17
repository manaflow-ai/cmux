# cmux iOS agent GUI research

This note records the first-party behavior used to design the new agent GUI. It
is intentionally separate from the existing Feed and terminal UI. Existing
cmux agent/session code was inventoried for transport and compatibility seams,
not used as a visual reference.

## First-party references

- [ChatGPT iOS FAQ](https://help.openai.com/en/articles/7885016-chatgpt-ios-app-faq)
- [Finding chats, projects, and files](https://help.openai.com/en/articles/10056348-finding-your-chats-projects-and-files-in-chatgpt)
- [Temporary chats](https://help.openai.com/en/articles/8914046-temporary-chat-in-chatgpt)
- [Uploads](https://help.openai.com/en/articles/8555545-uploading-files-and-audio-to-chatgpt)
- [Web search](https://help.openai.com/en/articles/9237897-searching-the-web-with-chatgpt)
- [Voice](https://help.openai.com/en/articles/20001274-chatgpt-voice)
- [Appearance](https://help.openai.com/en/articles/11958281-updating-your-visual-experience-on-chatgpt)
- [Mobile Codex](https://learn.chatgpt.com/docs/mobile)
- [Codex remote engineering](https://developers.openai.com/blog/mastering-codex-remote-for-engineering)
- [Codex app-server](https://learn.chatgpt.com/docs/app-server)
- [Codex permission modes](https://learn.chatgpt.com/docs/permission-modes)
- [Codex projects](https://learn.chatgpt.com/docs/projects)
- [Codex settings](https://learn.chatgpt.com/docs/reference/settings)
- [Codex code review](https://learn.chatgpt.com/docs/code-review)

Official Codex captures inspected during research:

- [Project picker](https://developers.openai.com/images/blog/mastering-codex-remote-for-engineering.jpg)
- [Execution context and empty composer](https://developers.openai.com/images/blog/mastering-codex-remote-worktree-branch.jpg)
- [Populated composer](https://developers.openai.com/images/blog/mastering-codex-remote-skills-plugins.jpg)
- [Inline review](https://developers.openai.com/images/blog/mastering-codex-remote-inline-review.jpg)

## Behavior matrix

The mobile shell must preserve these distinct states rather than reducing them
to a single spinner:

| Area | Required states |
| --- | --- |
| Navigation | empty, recents, pinned, archived, search, connected host, disconnected host |
| Composer | empty, multiline, attachments, pending upload, failed upload, dictation/editing, working turn |
| Agent turn | submitted, streaming, tool running, approval request, accepted, denied, cancelled, failed, done, reconnecting |
| Follow-up | send, queue, steer, interrupt, edit latest prompt, fork/side chat where supported |
| Review | changed-file summary, expanded diff, line comments, stale revision, unavailable source |
| Voice/accessibility | microphone permission states, captions, background return, Dynamic Type, VoiceOver, light/dark/system, iPad/landscape, RTL |

## cmux compatibility seams

The implementation uses the existing typed `CmuxAgentChat` protocol: session
descriptors, paged `ChatMessage` history, `ChatSessionEvent` live updates,
`mobile.chat.send`, `mobile.chat.interrupt`, `mobile.chat.answer`, and the
existing artifact loaders. The host discovers Claude Code, Codex, and OpenCode
sessions through its existing hook/transcript registry; OpenCode remains a
generic `ChatAgentKind.other("opencode")` value so older hosts continue to
decode it.
