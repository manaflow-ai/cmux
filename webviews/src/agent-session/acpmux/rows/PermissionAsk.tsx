// A permission ask as the transcript row and the pane's bottom stack draw it.
import { PermissionCard } from "../PermissionCard";
import { callNative } from "../callNative";
import { useT } from "../i18n";
import type { AcpmuxPermission } from "../model";
import { QuestionCard } from "../question/QuestionCard";
import type { QuestionReply } from "../question/model";

/// Answers `permission` with the option a button or key picked.
const answerPermission = (permission: AcpmuxPermission) => (optionId: string) =>
  void callNative("chat.permission", { permissionId: permission.permissionId, optionId });

/// Sends a question card's reply: the harness's option (absent cancels) and its answers. The card
/// shows a refusal (the promise rejects) and takes input again for a retry.
const replyToQuestion = (permission: AcpmuxPermission) => (sent: QuestionReply) =>
  callNative("chat.permission", {
    permissionId: permission.permissionId,
    ...(sent.optionId === undefined ? {} : { optionId: sent.optionId }),
    ...(sent.answers === undefined ? {} : { answers: sent.answers }),
  });

/// A permission ask: a question card when the request asks a question, else its option buttons.
export function PermissionAsk({
  permission,
  harness,
  focusComposer,
  shownChat,
  shortcuts,
  waiting = 0,
}: {
  permission: AcpmuxPermission;
  harness?: string;
  focusComposer?: () => void;
  /// The chat shown now, read when a deny's instructions are about to go: with it, the card can deny
  /// with what the agent should do instead (`denyWithFeedback`).
  shownChat?: { readonly current: string | undefined };
  /// False while a permission group's panel takes the shortcuts (permissionKeys.ts `cardTakesShortcuts`).
  shortcuts?: boolean;
  /// More asks waiting behind this one (snapshot `permissionsWaiting`).
  waiting?: number;
}) {
  const t = useT();
  if (!permission.question)
    return (
      <PermissionCard
        permission={permission}
        harness={harness}
        focusComposer={focusComposer}
        shortcuts={shortcuts}
        onAnswer={answerPermission(permission)}
        onDenyWithFeedback={shownChat && denyWithFeedback(permission, shownChat)}
        waiting={waiting}
      />
    );
  return (
    <>
      {waiting > 0 && <p className="acpmux-permission-waiting">{t("permission.moreWaiting", { n: waiting })}</p>}
      <QuestionCard question={permission.question} onReply={replyToQuestion(permission)} />
    </>
  );
}

/// Denies `permission`, then gives the agent what to do instead: into the running turn now (a
/// steer; an agent that cannot steer stops the turn and takes it as the next prompt). Sent only once
/// acpmux took the deny, so the agent never reads it before its tool is refused, and only to the chat
/// that asked: another chat shown meanwhile would take it as its own. False when the deny failed.
const denyWithFeedback =
  (permission: AcpmuxPermission, shownChat: { readonly current: string | undefined }) =>
  async (optionId: string, text: string): Promise<boolean> => {
    const chat = shownChat.current;
    try {
      await callNative("chat.permission", { permissionId: permission.permissionId, optionId });
    } catch {
      return false;
    }
    if (text && shownChat.current === chat)
      await callNative("chat.send", { text, attachments: [], steer: true }).catch(() => undefined);
    return true;
  };
