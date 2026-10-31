// Whether each chat's running tray (SubagentTray.tsx) is open. The tray starts folded to its one
// line header: a list of commands and subagents above the composer took the transcript's room
// (https://github.com/manaflow-ai/cmux/issues/28875). The person's click holds for that chat, across
// a switch to another chat and back (the tray remounts per chat, App.tsx `key={shownSessionId}`),
// for as long as the pane lives. Bounded: the oldest chats drop first.

const MAX_CHATS = 200;
const opened = new Map<string, boolean>();

/// The person's last choice for this chat's tray; undefined until they click its header.
export function trayOpenFor(chat: string | undefined): boolean | undefined {
  return chat === undefined ? undefined : opened.get(chat);
}

/// Keeps the person's choice for this chat's tray.
export function rememberTrayOpen(chat: string | undefined, open: boolean): void {
  if (chat === undefined) return;
  opened.delete(chat);
  opened.set(chat, open);
  if (opened.size > MAX_CHATS) opened.delete(opened.keys().next().value!);
}

/// Tests only: forget every chat's choice.
export function resetTrayOpenMemory(): void {
  opened.clear();
}
