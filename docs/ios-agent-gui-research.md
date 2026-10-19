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

## Layout and rendering

The execution-context reference places the text input above the attachment,
model/effort, microphone and send controls. Agent Chat uses that two-row
arrangement so a long instruction retains the full composer width. The current
session has one compact context row; transport identifiers are not presented as
workspace or computer names. Prompt bubbles use an adaptive neutral fill, while
agent prose is unboxed. Markdown presentation intents produce separate native
headings, paragraphs, lists, quotes, code blocks and tables, preserving inline
links and emphasis. Code and tables scroll horizontally within the transcript.

Apple HIG references consulted for the October 19 iteration:

- [Color](https://developer.apple.com/design/human-interface-guidelines/color):
  adaptive system colors and a visible icon/text for usage warnings.
- [Text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields):
  a multiline input with a persistent accessibility identity and placeholder.
- [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars):
  compact navigation and less frequent session actions in the More menu.
- [Typography](https://developer.apple.com/design/human-interface-guidelines/typography):
  system text styles, Dynamic Type, and a clear heading hierarchy.

The supplied first-party captures are references, not proof of pixel parity.
Simulator captures must establish the rendered layout, keyboard behavior, light
and dark appearance, and scrolling states before visual equivalence is claimed.

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

History and live events share one native model. Pending sends, queued prompts,
approval answers, and session launches belong to the current host connection;
replacing that connection invalidates their completions. Provider transcript
events remain authoritative for completed turns and regeneration state.

The current host transport controls terminal-owned provider processes. It can
send prompts and attachments, interrupt turns, and answer supported requests.
It cannot change a running process's model, permissions, sandbox, or plan mode.
Those controls are therefore not advertised, and explicit control updates fail
instead of acknowledging a metadata-only change. Local session fork, resume,
and reopen use provider launch commands; remote-tmux fork and reopen remain
unsupported.
