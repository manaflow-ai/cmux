import { createNoticeQueue } from "../../../ui/NoticeStack";
import { translate } from "../i18n";

/** The pane's share toasts (one queue per page; the header owns one Share control at a time). */
export const shareToasts = createNoticeQueue(1);

/** A daemon refusal's line for the dialog's status. */
export function shareFailureText(error: unknown): string {
  const code = (error as { code?: unknown } | undefined)?.code ?? (error as Error | undefined)?.message;
  if (code === "share.no_room") return translate("share.error.noRoom");
  if (code === "share.needs_sign_in") return translate("share.error.signIn");
  if (code === "gesture_required") return translate("share.error.gesture");
  if (code === "share.restrict_raced") return translate("share.error.restrictRaced");
  // Any other refusal is the daemon's or the server's English: the log keeps it, the status says
  // "That didn't finish. Try again."
  console.warn("agent pane: sharing failed", error);
  return translate("share.error.generic");
}
