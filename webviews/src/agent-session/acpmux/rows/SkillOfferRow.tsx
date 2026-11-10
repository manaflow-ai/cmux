import { memo } from "react";
import { SkillOfferCard } from "../conversation/SkillOfferCard";
import { type RowProps } from "./rowProps";
import { resolveSkill } from "./rowActions";

/// A skill offer on the closing turn of the third similar chat (conversation/SkillOfferCard.tsx):
/// Save and Not now go to the daemon (`_acpmux/skill_resolve`).
export const SkillOfferRow = memo(
  function SkillOfferRow({ row }: RowProps) {
    const offer = row.skill;
    return offer ? (
      <SkillOfferCard offer={offer} onResolve={(action, draft) => resolveSkill(offer.offerId, action, draft)} />
    ) : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
/// A skill offer in a replayed, guest or read-only subagent transcript: its draft with no buttons,
/// which would act on the owner's live chat.
export const ReadOnlySkillOfferRow = memo(
  function ReadOnlySkillOfferRow({ row }: RowProps) {
    return row.skill ? <SkillOfferCard offer={row.skill} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
