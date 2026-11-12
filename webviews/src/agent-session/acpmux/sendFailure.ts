// Why a prompt was not sent, as the person can act on it (Leo 2026-10-21: a failed send read
// "Not sent: trust.pending: answer the trust question for the folder first", and every failed
// message had its own Retry, Edit, Remove and Details). The cause comes from the refusal's
// reason and code (direct.ts copies acpmux's `data.reason` and `data.code` onto the error and the
// prompt's delivery), never from its words; the words and the code stay for Details.
import { translate } from "./i18n";
import { PrefixFlatCache } from "./conversation/prefixFlatMap";
import { DATE } from "./conversation/turns";
import type { ComposerAttachment } from "./attachments";
import type { AcpmuxRow } from "./model";
import { errorMessage } from "./transportErrors";
import { peerLinkFailure, peerLinkLine } from "./hostLine";

/// The causes the failure card names in its own words, with their own way out.
export type SendCause = "trust-pending" | "trust-untrusted" | "pane" | "too-large" | "host-away" | "other";

type CauseFields = { code?: unknown; reason?: unknown } | null | undefined;

const text = (value: unknown) => (typeof value === "string" && value ? value : undefined);

/// The cause of a refusal, or of a failed prompt's delivery record.
export function sendCause(fields: CauseFields): SendCause {
  const reason = text(fields?.reason);
  // The reasons acpmux's trust gate writes (trust_gate.rs), as isTrustRefusal reads them.
  if (reason === "trust.pending") return "trust-pending";
  if (reason === "trust.untrusted") return "trust-untrusted";
  // More than one message carries (`rpc::MAX_MESSAGE_BYTES`): the same prompt is refused again.
  if (reason === "message.too_large") return "too-large";
  // A request the pane's host would not take is the pane's bug, not something the person did.
  if (text(fields?.code) === "transport.intent_invalid") return "pane";
  // acpmux was still starting or reconnecting when the send's wait for it ran out
  // (sendWhenReady.ts): a plain sentence and Retry, never the transport's words or restart advice.
  const code = text(fields?.code);
  if (code === "native.not_connected" || code === "native.timed_out") return "host-away";
  return "other";
}

/// A trust cause: Trust folder fixes it, and Retry waits while the folder's question is open.
export const isTrustCause = (cause: SendCause) => cause === "trust-pending" || cause === "trust-untrusted";

/// Whether Retry can help: a prompt too large to send is refused the same way again, so its way
/// out is Edit (Leo, 2026-10-31: "this is completely hardlocked bc of message size").
export const retryHelps = (cause: SendCause) => cause !== "too-large";

/// The bytes an attachment puts in the prompt: its base64 or its text.
const promptBytes = (attachment: ComposerAttachment) => (attachment.data?.length ?? 0) + (attachment.text?.length ?? 0);

/// A prompt too large to send: the attachment that takes the most of it, by name, when one does.
function tooLargeText(attachments: readonly ComposerAttachment[]): string {
  const largest = attachments.reduce<ComposerAttachment | undefined>(
    (most, attachment) => (promptBytes(attachment) > (most ? promptBytes(most) : 0) ? attachment : most),
    undefined,
  );
  return largest
    ? translate("prompt.failure.tooLargeFile", { name: largest.name })
    : translate("prompt.failure.tooLarge");
}

/// The failed prompt's one sentence. `retried`: a Retry that was refused again says "Still"
/// (hq#2569 item 5), so the click visibly did something. `attachments`: the prompt's, so a prompt
/// too large to send names the one to take out.
export function failedSendText(
  error: unknown,
  retried: boolean,
  attachments: readonly ComposerAttachment[] = [],
): string {
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
    case "too-large":
      return tooLargeText(attachments);
    case "host-away":
      return translate("prompt.failure.hostAway");
    default:
      break;
  }
  // A refusal for want of a gesture names that (the generic refusal's text is about a pick):
  // posted input is never the person's (cx-ocdz), and the Retry click is.
  // A chat's machine that is not reachable is said in plain words, never as acpmux's own text (a
  // `peer_unreachable:` code, its link state and a command to run; hostLine.ts).
  const peer = peerLinkFailure(error);
  const reason =
    text(fields?.code) === "transport.gesture_required"
      ? translate("prompt.gestureReason")
      : peer
        ? peerLinkLine(peer, translate)
        : withoutCode(errorMessage(error), text(fields?.reason) ?? text(fields?.code));
  return translate(retried ? "prompt.stillNotSent" : "prompt.notSent", {
    reason: reason || translate("transport.refused"),
  });
}

/// The line a send that went back to the composer says in the transcript, or nothing. A send that
/// waited for the agent service and gave up (`host-away`: acpmux restarting, the app's connection
/// going) says nothing there: its words are back in the composer, the pane's own host line says
/// the service is away, and acpmux may well have the prompt already (its journal sends a lost one
/// again under the same id), so "Not sent yet" was wrong as often as right (Leo, 2026-11-12:
/// "STOP FUCKING SHOWING THESE FUCKING MESSAGES"). A failed row keeps its sentence and Retry.
export function heldSendNotice(error: unknown, attachments: readonly ComposerAttachment[] = []): string | undefined {
  const fields = error && typeof error === "object" ? (error as { code?: unknown; reason?: unknown }) : undefined;
  if (sendCause(fields) === "host-away") return undefined;
  return failedSendText(error, false, attachments);
}

/// acpmux words a refusal `<code>: <words>`: the words without the code the error already names.
function withoutCode(message: string, code: string | undefined): string {
  if (!code || !message.startsWith(`${code}:`)) return message;
  return message.slice(code.length + 1).trim() || message;
}

/// Failed prompts in a row that failed for the same cause: one card, under the last of them.
export type FailedRun = { rowIds: readonly string[] };

const failedPrompt = (row: AcpmuxRow) => row.kind === "user" && row.failed === true && !row.received && !row.incoming;
type Failure = { id: string; key: string; joins: boolean };
const NO_FAILURE: readonly Failure[] = [];
const failedReads = new PrefixFlatCache<AcpmuxRow, Failure>((row, index, rows) => {
  if (!failedPrompt(row)) return NO_FAILURE;
  let before = index - 1;
  while (before >= 0 && rows[before]!.kind === DATE) before -= 1;
  return [{ id: row.id, key: runKey(row), joins: before >= 0 && failedPrompt(rows[before]!) }];
});

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
  // Only the failed prompts, from a pass that reads only the rows a snapshot changed
  // (conversation/prefixFlatMap.ts); each says whether it follows another with only date lines between.
  for (const failure of failedReads.read(rows).items) {
    if (!failure.joins) run = undefined;
    if (run?.key !== failure.key) run = { key: failure.key, rowIds: [] };
    run.rowIds.push(failure.id);
    runs.set(failure.id, run);
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
