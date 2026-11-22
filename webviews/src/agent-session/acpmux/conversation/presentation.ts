// The chat's presentation, selectable per agent session. Transcript is the existing full view;
// Messages is the compact, bubble-oriented presentation that hides tool rows. The presentation
// only changes which rows are drawn; row components remain responsible for their own content.
//
// Each chat keeps its own choice in localStorage. A chat without an override follows the global
// `agentPane.display.presentation` setting from chatDisplay.ts.
import { useSyncExternalStore } from "react";
import {
  PRESENTATION_KEY,
  defaultPresentation,
  changeChatDisplay,
  useDefaultPresentation,
  type Presentation,
} from "../chatDisplay";

export { PRESENTATIONS, isPresentation, type Presentation } from "../chatDisplay";

const STORAGE_KEY = "cmux.acpmux.presentation";
/// The chats whose own presentation is kept; the oldest choice goes first.
const LIMIT = 200;

let own: Map<string, Presentation> | undefined;
const listeners = new Set<() => void>();

/// The choices as stored now; undefined when storage cannot be read.
function stored(): Map<string, Presentation> | undefined {
  try {
    const value = JSON.parse(globalThis.localStorage?.getItem(STORAGE_KEY) ?? "null") as unknown;
    const presentations = new Map<string, Presentation>();
    if (value && typeof value === "object")
      for (const [sessionId, presentation] of Object.entries(value as Record<string, unknown>))
        if (presentation === "transcript" || presentation === "messages") presentations.set(sessionId, presentation);
    return presentations;
  } catch {
    // Private windows, test DOMs and full storage keep the choices for this page only.
    return undefined;
  }
}

function load(): Map<string, Presentation> {
  own ??= stored() ?? new Map();
  return own;
}

/// Writes one chat's choice (or its removal) over what storage holds now, not this page's copy:
/// another pane's choices made since this page read them stay.
function write(sessionId: string, presentation: Presentation | undefined): void {
  const all = stored() ?? load();
  all.delete(sessionId);
  if (presentation) all.set(sessionId, presentation);
  while (all.size > LIMIT) all.delete(all.keys().next().value!);
  own = all;
  try {
    globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(Object.fromEntries(all)));
  } catch {
    // The in-memory choice still lasts for this page.
  }
}

// Another pane (another page on the same origin) changed a chat's presentation: read it again.
if (typeof globalThis.addEventListener === "function")
  globalThis.addEventListener("storage", (event: StorageEvent) => {
    if (event.key !== STORAGE_KEY && event.key !== null) return;
    own = stored() ?? own;
    for (const listener of listeners) listener();
  });

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

/// The chat's presentation: its own, else the global default setting.
export const presentationOf = (sessionId: string | undefined): Presentation =>
  (sessionId ? load().get(sessionId) : undefined) ?? defaultPresentation();

/// Whether the chat has a presentation of its own, even one equal to the default.
export const hasOwnPresentation = (sessionId: string | undefined): boolean =>
  sessionId !== undefined && load().has(sessionId);

/// The chat's presentation as a hook.
export function usePresentation(sessionId: string | undefined): Presentation {
  const fallback = useDefaultPresentation();
  const mine = useSyncExternalStore(
    subscribe,
    () => (sessionId ? load().get(sessionId) : undefined),
    () => undefined,
  );
  return mine ?? fallback;
}

/// Set a presentation for this chat only.
export function setPresentation(sessionId: string, presentation: Presentation): void {
  if (load().get(sessionId) === presentation && stored()?.get(sessionId) === presentation) return;
  write(sessionId, presentation);
  for (const listener of listeners) listener();
}

/// Make a presentation the global default and clear this chat's own override, if any.
export function makePresentationDefault(sessionId: string | undefined, presentation: Presentation): void {
  if (sessionId && load().has(sessionId)) write(sessionId, undefined);
  changeChatDisplay(PRESENTATION_KEY, presentation === "transcript" ? null : presentation);
  for (const listener of listeners) listener();
}

/// Test and gallery reset: every chat follows the global default again.
export function resetPresentations(): void {
  own = new Map();
  try {
    globalThis.localStorage?.removeItem(STORAGE_KEY);
  } catch {
    // Nothing to persist.
  }
  for (const listener of listeners) listener();
}
