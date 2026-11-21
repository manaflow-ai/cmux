import { NativeError } from "./nativeError";

/// The reason the app gave for refusing a page's `action.run` (AgentPaneModel+Actions.swift `refused`:
/// code `unavailable`, `details.reason`), such as Move to Cloud on a chat with no first message: "Send a
/// first message, then move this chat." Undefined for any other failure, and for an empty reason, so a
/// toast never shows empty text.
export function actionRefusal(error: unknown): string | undefined {
  if (!(error instanceof NativeError) || error.code !== "unavailable") return undefined;
  const reason = (error.details as { reason?: unknown } | null | undefined)?.reason;
  return typeof reason === "string" && reason.trim() ? reason : undefined;
}

/// A `.catch` for a page's `action.run`: says the app's reason in `say` (the pane's toasts), else
/// `fallback`'s text when there is one. A refusal the app gave a reason for is never dropped.
export function sayActionRefusal(say: (text: string) => void, fallback?: () => string): (error: unknown) => void {
  return (error) => {
    const text = actionRefusal(error) ?? fallback?.();
    if (text) say(text);
  };
}
