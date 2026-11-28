import { type Dispatch, type SetStateAction, useCallback, useRef, useState } from "react";

/** What the pane showed before another chat: that chat, and this state's value there. */
export type LeftChatState<T> = { chat: string | undefined; value: T };

/** A value set while the chat was shown for the `shown`th time. */
type Held<T> = { shown: number; value: T };

/**
 * State that belongs to a chat while it shows: each time another chat shows, it begins again at
 * `start(chat, left)`, in the render that shows it. The pattern it replaces, "another chat? set it
 * again" during render, makes React throw that render away and render the whole pane again on every
 * switch (settled-page bench, chat_switch: AcpmuxPane drawn twice a switch). `start` runs once a
 * switch, and its value keeps its identity across renders until a set. A set from a callback applies
 * to the chat shown last.
 */
export function useChatState<T>(
  chat: string | undefined,
  start: (chat: string | undefined, left?: LeftChatState<T>) => T,
): [T, Dispatch<SetStateAction<T>>] {
  const shows = useRef<{ chat: string | undefined; shown: number; begun: T } | undefined>(undefined);
  const [held, setHeld] = useState<Held<T> | undefined>(undefined);
  const now = shows.current;
  if (!now) shows.current = { chat, shown: 0, begun: start(chat) };
  else if (now.chat !== chat) {
    const left = { chat: now.chat, value: held?.shown === now.shown ? held.value : now.begun };
    shows.current = { chat, shown: now.shown + 1, begun: start(chat, left) };
  }
  const { shown, begun } = shows.current!;
  const value = held?.shown === shown ? held.value : begun;
  const set = useCallback<Dispatch<SetStateAction<T>>>((next) => {
    setHeld((from) => {
      const { shown, begun } = shows.current!;
      const base = from?.shown === shown ? from.value : begun;
      const value = typeof next === "function" ? (next as (current: T) => T)(base) : next;
      return Object.is(value, base) ? from : { shown, value };
    });
  }, []);
  return [value, set];
}
