// Why a prompt was not sent, as the person can act on it (Leo 2026-10-21: a failed send read
// "Not sent: trust.pending: answer the trust question for the folder first", and every failed
// message had its own Retry, Edit, Remove and Details). The cause comes from the refusal's
// reason and code (direct.ts copies acpmux's `data.reason` and `data.code` onto the error and the
// prompt's delivery), never from its words; the words and the code stay for Details.
import { translate } from "./i18n";
import { DATE } from "./conversation/turns";
import type { AcpmuxRow } from "./model";
import { errorMessage } from "./transportErrors";

/// The causes the failure card names in its own words, with their own way out.
export type SendCause = "trust-pending" | "trust-untrusted" | "pane" | "other";

type CauseFields = { code?: unknown; reason?: unknown } | null | undefined;

const text = (value: unknown) => (typeof value === "string" && value ? value : undefined);

/// The cause of a refusal, or of a failed prompt's delivery record.
export function sendCause(fields: CauseFields): SendCause {
  const reason = text(fields?.reason);
  // The reasons acpmux's trust gate writes (trust_gate.rs), as isTrustRefusal reads them.
  if (reason === "trust.pending") return "trust-pending";
  if (reason === "trust.untrusted") return "trust-untrusted";
  // A request the pane's host would not take is the pane's bug, not something the person did.
  if (text(fields?.code) === "transport.intent_invalid") return "pane";
  return "other";
}

/// A trust cause: Trust folder fixes it, and Retry waits while the folder's question is open.
export const isTrustCause = (cause: SendCause) => cause === "trust-pending" || cause === "trust-untrusted";

/// The failed prompt's one sentence. `retried`: a Retry that was refused again says "Still"
/// (hq#2569 item 5), so the click visibly did something.
export function failedSendText(error: unknown, retried: boolean): string {
  const fields = error && typeof error === "object" ? (error as { code?: unknown; reason?: unknown }) : undefined;
  switch (sendCause(fields)) {
    case "trust-pending":
      return translate("prompt.failure.trustPending");
    case "trust-untrusted":
      return translate("prompt.failure.trustUntrusted");
    case "pane":
      // The pane's bug, not the person's: logged for its report, as errorMessage logs it.
      console.error("agent pane: the host refused a request", error);
      return translate(retried ? "prompt.failure.paneAgain" : "prompt.failure.pane");
    default:
      break;
  }
  // A refusal for want of a gesture names that (the generic refusal's text is about a pick):
  // posted input is never the person's (cx-ocdz), and the Retry click is.
  const reason =
    text(fields?.code) === "transport.gesture_required"
      ? translate("prompt.gestureReason")
      : withoutCode(errorMessage(error), text(fields?.reason) ?? text(fields?.code));
  return translate(retried ? "prompt.stillNotSent" : "prompt.notSent", {
    reason: reason || translate("transport.refused"),
  });
}

/// acpmux words a refusal `<code>: <words>`: the words without the code the error already names.
function withoutCode(message: string, code: string | undefined): string {
  if (!code || !message.startsWith(`${code}:`)) return message;
  return message.slice(code.length + 1).trim() || message;
}

/// Failed prompts in a row that failed for the same cause: one card, under the last of them.
export type FailedRun = { rowIds: readonly string[] };

const failedPrompt = (row: AcpmuxRow) => row.kind === "user" && row.failed === true && !row.received && !row.incoming;

/// What makes two failures the same: acpmux's reason and the code, else the refuser's own words.
function runKey(row: AcpmuxRow): string {
  const { reason, code, error } = row.delivery ?? {};
  if (reason || code) return `${reason ?? ""}\u0000${code ?? ""}`;
  return `\u0001${error ?? row.error ?? row.id}`;
}

/// The run each failed prompt of the transcript is in. Only date lines may sit between two
/// prompts of a run; any other row (a reply, a sent prompt) ends it. `previous` comes back when
/// the runs are the same, so the card's context does not change on every streamed snapshot.
export function failedRuns(
  rows: readonly AcpmuxRow[],
  previous?: ReadonlyMap<string, FailedRun>,
): ReadonlyMap<string, FailedRun> {
  const runs = new Map<string, FailedRun>();
  let run: { key: string; rowIds: string[] } | undefined;
  for (const row of rows) {
    if (row.kind === DATE) continue;
    if (!failedPrompt(row)) {
      run = undefined;
      continue;
    }
    const key = runKey(row);
    if (run?.key !== key) run = { key, rowIds: [] };
    run.rowIds.push(row.id);
    runs.set(row.id, run);
  }
  if (previous && previous.size === runs.size) {
    let same = true;
    for (const [id, entry] of runs) {
      const was = previous.get(id)?.rowIds;
      if (!was || was.length !== entry.rowIds.length || was.some((other, index) => other !== entry.rowIds[index])) {
        same = false;
        break;
      }
    }
    if (same) return previous;
  }
  return runs;
}
