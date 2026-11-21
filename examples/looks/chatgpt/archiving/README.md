# Codex chat archive

![Codex thread rows in the sidebar](https://developers.openai.com/images/codex/app/multitask-light.webp)

Install the chat archive controls on their own.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/chatgpt/archiving@feat-cmux-next
```

From this directory, use `cmux customize use ./cmux-setup.json` to preview it. Choose `cmux customize apply` to keep it or `cmux customize discard` to return to the applied settings.

**Archive a chat.** Hover over a Priority row or open its context menu and choose Archive Chat. That action targets the chat under the pointer, including when another chat is open. For the focused conversation, press ⇧⌘A. The binding is scoped to an agent pane. A local chat keeps its history. Reopen the archived chat from search and choose Unarchive in its chat menu.

**Settle finished work.** For the optional Settled fold, preview the accompanying profile with `cmux customize use ./settle.json` on a build with Settle Finished Chats, then run `cmux customize apply`. This groups seen, finished chats. Expand Settled to see them again. New work or an unread response brings a chat back into the list. Archive Settled Chats is a separate, explicit bulk workspace action with Undo. Enabling the fold alone leaves every chat's archive state intact.

**Restore location.** The source app offers archived chats in settings. The restore path in this setup uses chat search and the conversation menu. The captured source menu presents Archive separately from permanent deletion.

[Archive a chat or project’s chats](https://learn.chatgpt.com/docs/projects?surface=app) · [Restore archived chats](https://learn.chatgpt.com/docs/reference/settings)
