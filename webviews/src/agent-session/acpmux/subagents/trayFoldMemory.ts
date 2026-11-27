// Whether each chat's running tray (SubagentTray.tsx) is open. The tray starts folded to its one
// line header: a list of commands and subagents above the composer took the transcript's room
// (https://github.com/manaflow-ai/cmux/issues/28875). The person's click holds for that chat, across
// a switch to another chat and back (the tray remounts per chat, App.tsx `key={shownSessionId}`),
// for as long as the pane lives. Bounded: the chats least recently shown or clicked drop first.

const MAX_CHATS = 200;
const opened = new Map<string, boolean>();

/// The person's last choice for this chat's tray; undefined until they click its header.
export function trayOpenFor(chat: string | undefined): boolean | undefined {
  const open = chat === undefined ? undefined : opened.get(chat);
  if (open !== undefined) rememberTrayOpen(chat, open);
  return open;
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

// The hat that comes back under the pointer that clicked its pull tab. The pull tab (TrayPullTab.tsx)
// and the hat's tuck chevron (SubagentTray.tsx) stand at the same place on the composer's top edge, and
// the hat remounts on the click: its chevron would show right under the stationary pointer and the
// next click there would tuck the hat again, strip to pill to strip with one pointer (Leo, 2026-11-27,
// a recording of a hat flipping between its strip, its "^ 20" pill and its list: "this isn't great").
// So a hat that returns this way keeps its tuck chevron away until the pointer has left it once.
let pointerUntucked = false;

/// The pull tab's pointer click brought the hat back: its next mount keeps the tuck away.
export function markUntuckedByPointer(): void {
  pointerUntucked = true;
}

/// Read once by the hat that mounts next.
export function takeUntuckedByPointer(): boolean {
  const was = pointerUntucked;
  pointerUntucked = false;
  return was;
}
