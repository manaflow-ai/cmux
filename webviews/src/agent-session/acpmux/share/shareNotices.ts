import { createNoticeQueue } from "../../../ui/NoticeStack";
import { translate } from "../i18n";
import { NativeError } from "../nativeError";

/** The pane's share toasts (one queue per page; the header owns one Share control at a time). */
export const shareToasts = createNoticeQueue(1);

/** A daemon refusal the dialog has its own words for, else undefined. */
export function shareRefusalText(error: unknown): string | undefined {
  const code = (error as { code?: unknown } | undefined)?.code ?? (error as Error | undefined)?.message;
  if (code === "share.no_room") return translate("share.error.noRoom");
  if (code === "share.needs_sign_in") return translate("share.error.signIn");
  if (code === "gesture_required") return translate("share.error.gesture");
  if (code === "share.restrict_raced") return translate("share.error.restrictRaced");
  if (code === "share.bad_request") return translate("share.error.badAccount");
  if (code === "share.limit") return translate("share.error.limit");
  if (code === "share.room_unreachable") return translate("share.error.offline");
  if (code === "share.room_refused") return translate("share.error.refused");
  // The app's own sentence for a share refusal (AgentShareStrings: share.room_unconfigured's "This
  // Cloud machine can't make share links yet…", share.not_owner's, …) arrives as a bridge
  // error's message, already in the app's language: the person reads that, not the generic line.
  if (
    error instanceof NativeError &&
    typeof code === "string" &&
    code.startsWith("share.") &&
    error.message.trim() !== "" &&
    error.message !== translate("error.requestFailed")
  )
    return error.message;
  return undefined;
}

/** A daemon refusal's line for the dialog's status, after a step (a write) failed. */
export function shareFailureText(error: unknown): string {
  // Any other refusal is the daemon's or the server's English: the log keeps it, the status says
  // "That didn't finish. Try again." plus the refusal's code when it has one, so a report names it.
  const known = shareRefusalText(error);
  if (known) return known;
  console.warn("agent pane: sharing failed", error);
  // retry-prompt-ok: a step is a write (an invite, a role, a removal, a link); doing it again is the person's choice.
  const code = (error as { code?: unknown } | undefined)?.code ?? (error as Error | undefined)?.message;
  const generic = translate("share.error.generic");
  return typeof code === "string" && /^[a-z]+(?:[._][a-z]+)+$/.test(code) ? `${generic} (${code})` : generic;
}
