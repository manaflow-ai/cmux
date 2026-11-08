import { NativeError } from "./nativeError";
import type { NeedsYouAnswer, NeedsYouItem } from "./needsYou/model";

/// What became of an answer given here: `answered` (the host answered it; the row hides until
/// acpmux takes it off) or `opened` (the host can't answer it here and opened its chat, whose card
/// answers it; the row stays).
export type HomeInboxOutcome = "answered" | "opened";

/// Answers another chat's ask from the home's inbox (`chat.asks.answer`, CmuxNextAgentPane
/// AgentPaneAskAnswer): the host takes it only on the person's own click or key, for an ask still
/// pending in a chat on this Mac's acpmux, with that ask's allow once or deny once. A host that does
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

/// The answers a row gives in place: an approval's allow and deny. A question's choices, a held
/// pair and a chat with no ask read here open the chat, where the whole ask shows.
export const inlineAnswers = (item: NeedsYouItem) =>
  item.kind === "approval" || item.kind === "verify" ? item.answers.filter((a) => a.tone !== "choice") : [];
