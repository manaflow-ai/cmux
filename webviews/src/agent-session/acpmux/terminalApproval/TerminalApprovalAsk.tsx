import { useMemo } from "react";
import { callNative } from "../callNative";
import { PermissionCard } from "../PermissionCard";
import {
  TERMINAL_APPROVAL_ANSWER_OP,
  type TerminalApproval,
  terminalApprovalAnswer,
  terminalApprovalPermission,
} from "./terminalApproval";

/// Picks the option in the terminal through the host; rejects when the host typed nothing (the
/// terminal shows another dialog, or none), which the card shows.
function answerInTerminal(approval: TerminalApproval) {
  return (optionId: string) => {
    const answer = terminalApprovalAnswer(approval, optionId);
    if (!answer) return Promise.reject(new Error("no such option"));
    return callNative(TERMINAL_APPROVAL_ANSWER_OP, answer);
  };
}

/// The terminal's approval dialog as this chat's permission card (terminalApproval.ts): the same
/// card, keys and look as an ask acpmux sends, answered in the terminal.
export function TerminalApprovalAsk({
  approval,
  shortcuts,
  focusComposer,
}: {
  approval: TerminalApproval;
  shortcuts?: boolean;
  focusComposer?: () => void;
}) {
  const permission = useMemo(() => terminalApprovalPermission(approval), [approval]);
  return (
    <PermissionCard
      key={permission.permissionId}
      permission={permission}
      harness={approval.harness}
      shortcuts={shortcuts}
      focusComposer={focusComposer}
      onAnswer={answerInTerminal(approval)}
    />
  );
}
