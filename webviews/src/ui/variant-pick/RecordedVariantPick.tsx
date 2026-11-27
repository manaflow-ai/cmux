import { useState } from "react";
import { VariantPick, type VariantOption } from "./VariantPick";
import type { PickContext, PickRecord, PickSink } from "./model";
import { noopFeedSink, recordPick } from "./sinks";
import { variantPickStrings } from "./strings";
import type { Strings } from "../../pages/shared/i18n";

export interface RecordedVariantPickProps {
  context: PickContext;
  options: readonly VariantOption[];
  recommendedId?: string;
  beads: PickSink;
  feed?: PickSink;
  strings?: Strings;
  onRecorded?(receipt: PickRecord): void;
}

/** Mount with a context key: each entry/turn owns its own saved choice. */
export function RecordedVariantPick({
  context,
  options,
  recommendedId,
  beads,
  feed = noopFeedSink,
  strings = variantPickStrings(),
  onRecorded,
}: RecordedVariantPickProps) {
  const [currentPick, setCurrentPick] = useState<string | null>(null);
  const [note, setNote] = useState("");
  return (
    <>
      <VariantPick
        options={options}
        recommendedId={recommendedId}
        currentPick={currentPick}
        strings={strings}
        onPick={async (variantId) => {
          const receipt = await recordPick(
            { ...context, variantId, recommendedId, who: "", when: "", note },
            beads,
            feed,
          );
          setCurrentPick(receipt.variantId);
          onRecorded?.(receipt);
        }}
      />
      <label className="variant-pick-note">
        {strings.t("note")}
        <textarea
          aria-label={strings.t("note")}
          value={note}
          onChange={(event) => setNote(Array.from(event.target.value).slice(0, 500).join(""))}
        />
      </label>
    </>
  );
}
