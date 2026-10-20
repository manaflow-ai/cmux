import { useSyncExternalStore } from "react";
const listeners = new Set<() => void>();
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

/// The thread's project and title at the header's start (header/ThreadTitle.tsx), for trying the
/// design: `threadTitle: true` in `agent-pane/layout.json`, or `?data-thread-title=on` in the dev server.
let threadTitleOn = false;

export function configureThreadTitle(layout: Record<string, unknown> | undefined): void {
  const next = layout?.threadTitle === true;
  if (next === threadTitleOn) return;
  threadTitleOn = next;
  for (const listener of listeners) listener();
}

const threadTitleShown = () =>
  threadTitleOn || (typeof document !== "undefined" && document.documentElement.dataset.threadTitle === "on");

/// Whether the header shows the thread's project and title.
export const useThreadTitle = (): boolean => useSyncExternalStore(subscribe, threadTitleShown, threadTitleShown);
