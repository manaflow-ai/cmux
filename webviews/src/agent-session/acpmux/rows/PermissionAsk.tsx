import { type AcpmuxPermission } from "../model";
import { PermissionCard } from "../PermissionCard";
import { PermissionQuestion } from "../question/PermissionQuestion";
import type { QuestionReply } from "../question/model";
import { useT } from "../i18n";
import { callNative } from "../callNative";

/// Answers `permission` with the option a button or key picked; rejects when acpmux refused it, which
/// the card shows.
const answerPermission = (permission: AcpmuxPermission) => (optionId: string) =>
  callNative("chat.permission", { permissionId: permission.permissionId, optionId });

/// Sends a question card's reply: the harness's option (absent cancels) and its answers. The card
/// shows a refusal (the promise rejects) and takes input again for a retry.
const replyToQuestion = (permission: AcpmuxPermission, sent: QuestionReply) =>
  callNative("chat.permission", {
    permissionId: permission.permissionId,
    ...(sent.optionId === undefined ? {} : { optionId: sent.optionId }),
    ...(sent.answers === undefined ? {} : { answers: sent.answers }),
    ...(sent.annotations === undefined ? {} : { annotations: sent.annotations }),
  });

/// A permission ask: a question card when the request asks a question, else its option buttons.
export function PermissionAsk({
  permission,
  harness,
  fullAccessMode,
  focusComposer,
  shownChat,
  shortcuts,
  waiting = 0,
  alwaysAtSource,
  onDraft,
}: {
  permission: AcpmuxPermission;
  harness?: string;
  /// The chat's highest mode while it runs it: the card says the mode does not answer this ask.
  fullAccessMode?: string;
  focusComposer?: () => void;
  /// The chat shown now, read when a deny's instructions are about to go: with it, the card can deny
  /// with what the agent should do instead (`denyWithFeedback`).
  shownChat?: { readonly current: string | undefined };
  /// False while a permission group's panel takes the shortcuts (permissionKeys.ts `cardTakesShortcuts`).
  shortcuts?: boolean;
  /// More asks waiting behind this one (snapshot `permissionsWaiting`).
  waiting?: number;
  /// A peer's chat, which takes no lasting grant from this Mac (PermissionCard).
  alwaysAtSource?: boolean;
  /// The card's deny instructions opened or closed (PermissionCard `onDraft`).
  onDraft?: (open: boolean) => void;
}) {
  const t = useT();
  if (!permission.question)
    return (
      <PermissionCard
        permission={permission}
        alwaysAtSource={alwaysAtSource}
        harness={harness}
        fullAccessMode={fullAccessMode}
        focusComposer={focusComposer}
        shortcuts={shortcuts}
        onAnswer={answerPermission(permission)}
        onDenyWithFeedback={shownChat && denyWithFeedback(permission, shownChat)}
        onDraft={onDraft}
        waiting={waiting}
      />
    );
  return (
    <>
      {waiting > 0 && <p className="acpmux-permission-waiting">{t("permission.moreWaiting", { n: waiting })}</p>}
      <PermissionQuestion permission={permission} question={permission.question} send={replyToQuestion} />
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
