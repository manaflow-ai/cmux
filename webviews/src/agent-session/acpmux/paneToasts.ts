// Where the agent pane says something back. Two routes:
//
// - `transcript`: a line in the shown chat, for what belongs to the conversation (a prompt that was
//   not sent, a resume that failed). It stays with the rows it is about.
// - `transient`: feedback on a click or an action (a sender with no chat, an action the app did not
//   run). It belongs to the moment, not the chat: a toast in the pane's stack over the transcript's
//   foot, by the composer where the person is looking (Leo, 2026-11-07: "it should have sent, like,
//   that bottom toast area"). The same text twice is one toast with a count (NoticeStack). A click
//   that failed (`failed`) is the same toast drawn as an error, so it never reads as plain news.
//
// In the app the toast is the app's own native toast (`pane.toast`), so it takes the toast style picked
// in the Toast Playground like every other toast (Lawrence, 2026-11-13). The page's own stack draws it
// only without a native host (the browser dev page) or when the host refuses it.
import { anchorMemory } from "../../ui/anchors";
import { createNoticeQueue, type NoticeQueue } from "../../ui/NoticeStack";
import { translate } from "./i18n";
import { hasNativeHost, postNative } from "./native";

/** The shown chat's notice lines (DirectClient.notice). */
export interface TranscriptNotices {
  notice(text: string): unknown;
}

export interface PaneNoticeSinks {
  /** The client of the shown chat, when there is one. */
  transcript(): TranscriptNotices | null | undefined;
  /** The pane's toast queue. */
  toasts: NoticeQueue;
  /** Shows the toast natively; resolves false when the host cannot (the page then draws it). */
  native?: (toast: NativePaneToast) => Promise<boolean>;
}

/** A feedback toast as the native host shows it (`pane.toast`). */
export interface NativePaneToast {
  message: string;
  tone: "neutral" | "error";
  group: string;
}

/** `pane.toast` through the pane's native bridge; false when there is no host or it refuses. */
export async function postNativePaneToast(toast: NativePaneToast): Promise<boolean> {
  if (!hasNativeHost()) return false;
  try {
    await postNative("pane.toast", { ...toast });
    return true;
  } catch {
    return false;
  }
}

export interface PaneNotices {
  transcript(text: string): void;
  /** `group`: the kind of toast, which a drag's anchor is remembered under. */
  transient(text: string, group?: string): void;
  /** A click or action that failed: a transient toast drawn as an error. `text` is plain words. */
  failed(text: string): void;
  /** A sender chip whose name acpmux resolves to no chat. */
  senderMissing(name: string): void;
}

/** The pane's toasts: at most three in the deck, the oldest leaving for a fourth. */
export const PANE_TOAST_LIMIT = 3;

/** Where each kind of toast was last dragged (anchors.ts), in the page's localStorage. */
export const PANE_TOAST_ANCHOR_PREFIX = "cmux.agentPane.toastAnchor.";

export function createPaneToasts(): NoticeQueue {
  return createNoticeQueue(PANE_TOAST_LIMIT, { anchors: anchorMemory(PANE_TOAST_ANCHOR_PREFIX) });
}

export function paneNotices(sinks: PaneNoticeSinks): PaneNotices {
  const transcript = (text: string) => void sinks.transcript()?.notice(text);
  const drawn = (text: string, group: string, kind?: "error") =>
    sinks.toasts.show({ message: text, group, ...(kind ? { kind } : {}) });
  const transient = (text: string, group = "feedback", kind?: "error") => {
    if (!text) return;
    const native = sinks.native;
    if (!native) return void drawn(text, group, kind);
    void native({ message: text, tone: kind === "error" ? "error" : "neutral", group }).then(
      (shown) => {
        if (!shown) drawn(text, group, kind);
      },
      () => drawn(text, group, kind),
    );
  };
  return {
    transcript,
    transient: (text, group) => transient(text, group),
    failed: (text) => transient(text, "feedback", "error"),
    senderMissing: (name) => transient(translate("message.senderNotFound", { name }), "senderMissing"),
  };
}
