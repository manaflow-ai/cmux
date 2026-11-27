import { memo } from "react";
import { PresetApprovalCard } from "../conversation/PresetApprovalCard";
import { type RowProps } from "./rowProps";
import { answerPresetApproval } from "./rowActions";

/// A no-prompt preset's approval card where acpmux refused the agent's start
/// (conversation/PresetApprovalCard.tsx): Approve and Not now go to acpmux (`_acpmux/presets`).
export const PresetApprovalRow = memo(
  function PresetApprovalRow({ row }: RowProps) {
    const approval = row.presetApproval;
    return approval ? (
      <PresetApprovalCard
        approval={approval}
        onAnswer={(outcome) => answerPresetApproval(row.id, outcome === "approved")}
      />
    ) : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
/// A preset approval in a replayed or read-only subagent transcript: the card with no buttons,
/// which would act on the live chat.
export const ReadOnlyPresetApprovalRow = memo(
  function ReadOnlyPresetApprovalRow({ row }: RowProps) {
    return row.presetApproval ? <PresetApprovalCard approval={row.presetApproval} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
