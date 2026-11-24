import { NativeError } from "./nativeError";
import type { NeedsYouAnswer, NeedsYouItem } from "./needsYou/model";
import { reply, replyParams, selection, type QuestionReply } from "./question/model";

/// What became of an answer given here: `answered` (the host answered it; the row hides until
/// acpmux takes it off) or `opened` (the host can't answer it here and opened its chat, whose card
/// answers it; the row stays).
export type HomeInboxOutcome = "answered" | "opened";

/// Answers another chat's ask from the home's inbox (`chat.asks.answer`, CmuxNextAgentPane
/// AgentPaneAskAnswer): the host takes it only on the person's own click, for an ask still pending
/// in a chat on this Mac's acpmux, with that ask's allow once or deny once, or for a question the
/// choice as its own card sends it (`replyElsewhere`). A host that does
/// not answer it here opens the chat, whose card answers it: `unsupported` (another computer's chat
/// or daemon, or the pane's own host before the op), or the shared page host without the op
/// (`callPageHost` reports its `cmux.protocol.unknown_op` as `native.invalid_request` with the
/// protocol code in `details`). Any other refusal, a malformed request's `invalid_params` included,
/// rejects, and the row says so.
const notAnsweredHere = (error: NativeError) =>
  error.code === "unsupported" ||
  (error.code === "native.invalid_request" &&
    (error.details as { protocol?: unknown } | undefined)?.protocol === "cmux.protocol.unknown_op");

export async function answerFromHome(
  call: (method: string, params: Record<string, unknown>) => Promise<unknown>,
  item: NeedsYouItem,
  choice: NeedsYouAnswer,
  open: (sessionId: string) => void,
): Promise<HomeInboxOutcome> {
  if (!item.permissionId) throw new Error("unanswerable");
  if (item.question) {
    // One pick of a one-question ask, in its harness's shape; `reply` throws on one it can't take.
    const first = item.question.items[0];
    if (!first) throw new Error("unanswerable");
    const sent = reply(item.question, { selections: { [first.id]: selection([choice.id]) } });
    return replyElsewhere(call, sent, () => open(item.sessionId));
  }
  try {
    await call("chat.asks.answer", {
      sessionId: item.sessionId,
      permissionId: item.permissionId,
      optionId: choice.id,
    });
    return "answered";
  } catch (error) {
    if (!(error instanceof NativeError) || !notAnsweredHere(error)) throw error;
    open(item.sessionId);
    return "opened";
  }
}

/// Answers another chat's question in place with the reply its own card would send (question/model.ts
/// `reply`: the choices and any typed Other, in its harness's shape). The pane's relay answers only
/// the chat it shows, so the host sends it (`chat.asks.answer` with `answers`, AgentPaneAskAnswer),
/// on the person's fresh click, after checking it against the question acpmux holds. A host that
/// can't (another computer's chat, an older host) opens the chat, whose card answers it. Leo,
/// 2026-11-10, of a question he could only open: "this is unusable to respond to i necessarily have
/// to open... this is bad ui".
export async function replyElsewhere(
  call: (method: string, params: Record<string, unknown>) => Promise<unknown>,
  sent: QuestionReply,
  open: () => void,
): Promise<HomeInboxOutcome> {
  try {
    await call("chat.asks.answer", replyParams(sent));
    return "answered";
  } catch (error) {
    // The host refuses a question it can't send here (one acpmux holds in another shape): its
    // chat's card answers it, so it opens rather than leave the row stuck.
    if (!(error instanceof NativeError) || !(notAnsweredHere(error) || error.code === "refused")) throw error;
    open();
    return "opened";
  }
}

/// The answers a row gives in place: an approval's allow and deny, and a one-pick question's
/// choices (needsYou/model.ts `questionAnswers`). A longer question, a held pair and a chat with no
/// ask read here open the chat, where the whole ask shows.
export const inlineAnswers = (item: NeedsYouItem) =>
  item.question && item.permissionId
    ? item.answers
    : item.kind === "approval" || item.kind === "verify"
      ? item.answers.filter((a) => a.tone !== "choice")
      : [];
