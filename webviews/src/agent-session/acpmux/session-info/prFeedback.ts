// Changes' Fix Failing Checks and Send Review Comments (Labs): a pull request's ⋯ menu asks acpmux
// (`_acpmux/pr_feedback`) to write a message about the pull request's own failing checks or its open
// review comments, and the message goes into the composer after what is typed, unsent. The person
// reads it, edits it and sends it. Nothing here ever sends.
import { useSyncExternalStore } from "react";
import { translate } from "../i18n";
import { errorMessage } from "../transportErrors";

export type PrFeedbackKind = "checks" | "comments";

/// Asks acpmux for the message about pull request `url`, for the chat shown now: its answer, and
/// whether that chat is still the one shown.
export type PrFeedbackRequest = (
  url: string,
  kind: PrFeedbackKind,
) => { answer: Promise<unknown>; stillShown: () => boolean };

let previewOn = false;
const listeners = new Set<() => void>();

/// Preview features on or off (`labs.previewFeatures`, off by default; App.tsx `applyPreview`).
export function setPrFeedbackPreview(on: boolean): void {
  if (on === previewOn) return;
  previewOn = on;
  for (const listener of listeners) listener();
}

/// Whether Changes offers the two items now.
export function usePrFeedbackPreview(): boolean {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => previewOn,
  );
}

/// The items a pull request row's ⋯ menu offers. `failing` and `onBase` are the row's own counts
/// (ChangesSection): -1 failing is failing with no count. Fix Failing Checks needs a red that is the
/// branch's own, so a pull request whose reds all fail on base too has none; an ended one has neither.
export function prFeedbackKinds(ended: boolean, failing: number, onBase: number): PrFeedbackKind[] {
  if (ended) return [];
  return failing === -1 || failing > onBase ? ["checks", "comments"] : ["comments"];
}

/// `owner/repo#N` for a GitHub pull request's address, else the address itself.
export function pullRequestReference(url: string): string {
  const match = /^https?:\/\/[^/]+\/([^/]+\/[^/]+)\/pull\/(\d+)/.exec(url);
  return match ? `${match[1]}#${match[2]}` : url;
}

/// What a click on either item does. A message goes into the composer (`quote`); an empty answer
/// (nothing of the branch's own to fix, no open comments) is acpmux's one line, said as a toast
/// (`notice`); a failure is said as an error toast (`failed`). A second click on the same item
/// while its request runs does nothing. A message for a chat the person left while it was read is
/// dropped, never put into the chat shown now. It returns the request's settling, for tests.
export function prFeedbackDispatcher({
  request,
  quote,
  notice,
  failed,
}: {
  request: PrFeedbackRequest;
  quote: (markdown: string) => void;
  notice: (text: string) => void;
  failed: (text: string) => void;
}): (url: string, kind: PrFeedbackKind) => Promise<void> | undefined {
  const running = new Set<string>();
  return (url, kind) => {
    const key = `${kind} ${url}`;
    if (running.has(key)) return undefined;
    running.add(key);
    const fail = (error: unknown) =>
      failed(
        translate("sessionInfo.changes.feedbackFailed", {
          reference: pullRequestReference(url),
          error: errorMessage(error) || translate("error.requestFailed"),
        }),
      );
    const asked = request(url, kind);
    return asked.answer
      .then((answer) => {
        if (!asked.stillShown()) return;
        const { draft, empty } = (answer && typeof answer === "object" ? answer : {}) as {
          draft?: unknown;
          empty?: unknown;
        };
        if (typeof draft !== "string" || !draft.trim()) fail(undefined);
        else if (empty === true) notice(draft);
        else quote(draft);
      }, fail)
      .finally(() => running.delete(key));
  };
}
