import type { AcpmuxSnapshot } from "../model";

/// Continue In…'s review no longer starts from any surface: a model switch, the chat menu's Continue
/// In…, `/continue` and the app's command all fork the chat in place (App.tsx `chat.switchModel`;
/// Leo 2026-11-11: "An extra menu with a questionnaire is not seamless"). Only a draft an earlier
/// build made still shows, so it can be started or discarded.
/// The chat's own continuation waits for its review in this tab: a draft or starting handoff that
/// targets this chat and has no receipt yet.
export function reviewingHandoff(snapshot: AcpmuxSnapshot): boolean {
  const handoff = snapshot.handoff?.record;
  return (
    !!handoff &&
    handoff.target.sessionId === snapshot.sessionId &&
    ["draft", "starting"].includes(handoff.state) &&
    !snapshot.handoff?.receipt
  );
}
