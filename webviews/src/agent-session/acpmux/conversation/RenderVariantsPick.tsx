import type { ReactNode } from "react";
import { RecordedVariantPick } from "../../../ui/variant-pick/RecordedVariantPick";
import type { PickRecord, PickSink } from "../../../ui/variant-pick/model";
import type { Strings } from "../../../pages/shared/i18n";

/** Structural adapter for Leo's RenderCall: retain a tool-call id when assembling the turn. */
export function RenderVariantsPick<T extends { id: string; title?: string; recommended?: boolean }>({
  calls,
  threadId,
  turnId,
  beads,
  feed,
  renderPreview,
  strings,
  onRecorded,
}: {
  calls: readonly T[];
  threadId: string;
  turnId: string;
  beads: PickSink;
  feed: PickSink;
  renderPreview(call: T, index: number): ReactNode;
  strings?: Strings;
  onRecorded?(receipt: PickRecord): void;
}) {
  return (
    <RecordedVariantPick
      key={`${threadId}:${turnId}`}
      context={{ threadId }}
      beads={beads}
      feed={feed}
      strings={strings}
      onRecorded={onRecorded}
      recommendedId={calls.find((call) => call.recommended)?.id}
      options={calls.map((call, index) => ({
        id: call.id,
        label: call.title ?? call.id,
        preview: renderPreview(call, index),
      }))}
    />
  );
}
