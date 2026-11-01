// A local presentation preference, keyed by conversation. Missing/invalid values keep today's look.
import { useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";

export type Presentation = "messages" | "transcript";
const prefix = "cmux.home.presentation:";
const listeners = new Set<() => void>();
const fallback = new Map<string, Presentation>();

export function readPresentation(conversation?: string): Presentation {
  if (!conversation) return "messages";
  if (fallback.has(conversation)) return fallback.get(conversation)!;
  try {
    return window.localStorage.getItem(prefix + conversation) === "transcript" ? "transcript" : "messages";
  } catch {
    return fallback.get(conversation) ?? "messages";
  }
}

export function setPresentation(conversation: string, value: Presentation): void {
  try {
    if (value === "messages") window.localStorage.removeItem(prefix + conversation);
    else window.localStorage.setItem(prefix + conversation, value);
    fallback.delete(conversation);
  } catch {
    // Storage can be unavailable; the choice still works for this page's lifetime.
    fallback.set(conversation, value);
  }
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  const changed = (event: StorageEvent) => {
    if (event.key === null || event.key.startsWith(prefix)) listener();
  };
  window.addEventListener("storage", changed);
  return () => {
    listeners.delete(listener);
    window.removeEventListener("storage", changed);
  };
}

export function usePresentation(conversation?: string): Presentation {
  return useSyncExternalStore(
    subscribe,
    () => readPresentation(conversation),
    () => "messages",
  );
}

export function PresentationToggle({ conversation, strings }: { conversation: string; strings: Strings }) {
  const presentation = usePresentation(conversation);
  return (
    <div className="lg-presentation" role="group" aria-label={strings.t("presentation.label")}>
      {(["messages", "transcript"] as const).map((value) => (
        <button
          key={value}
          type="button"
          aria-pressed={presentation === value}
          onClick={() => setPresentation(conversation, value)}
        >
          {strings.t(`presentation.${value}`)}
        </button>
      ))}
    </div>
  );
}
