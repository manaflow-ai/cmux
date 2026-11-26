/// The one fork glyph (the pack's `agent.fork`, design/icons/source/agent-composer.json): every surface that
/// offers or marks a fork draws it, the message action row, the chat menu, the send menu's side chat and the
/// model picker's fork mark. The app's menus and palette draw the same drawing through the icon catalog's
/// `overrides`. It is the split arrow Claude and Codex draw for branching a chat (Leo 2026-11-22: "dont get cute
/// about it; let's just do claude and codex's symbol for branching/forking chats"). forkIcon.test.ts holds every
/// surface to it.
export const FORK_ICON = "agent.fork";
