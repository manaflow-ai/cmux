import { useMemo } from "react";
import type { AcpmuxPermission } from "../model";
import type { AgentQuestion, QuestionReply } from "./model";
import { QuestionCard } from "./QuestionCard";

/// Sends a question card's reply for its permission (App.tsx `replyToQuestion`, a module-level
/// function, so it never changes between renders).
export type SendQuestionReply = (permission: AcpmuxPermission, reply: QuestionReply) => void | Promise<unknown>;

/// The live ask's question card. It keeps one reply handler per permission, so the memoized card
/// skips the pane's other updates (a streaming reply re-renders the pane on every token).
export function PermissionQuestion({
  permission,
  question,
  send,
}: {
  permission: AcpmuxPermission;
  /// `permission.question`, passed apart so the caller needn't make a narrowed copy each render.
  question: AgentQuestion;
  send: SendQuestionReply;
}) {
  const onReply = useMemo(() => (reply: QuestionReply) => send(permission, reply), [permission, send]);
  return <QuestionCard question={question} onReply={onReply} />;
}
