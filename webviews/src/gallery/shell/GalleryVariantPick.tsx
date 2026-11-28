import { useState, type ReactNode } from "react";
import type { GalleryEntry } from "../format";
import { RecordedVariantPick } from "../../ui/variant-pick/RecordedVariantPick";
import { beadsPickSink } from "../../ui/variant-pick/sinks";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import { variantPickStrings } from "../../ui/variant-pick/strings";
import "../../ui/ui.css";

export function GalleryVariantPick({
  entry,
  locale,
  preview,
}: {
  entry: GalleryEntry;
  locale: string;
  preview(variant: string): ReactNode;
}) {
  const [container, setContainer] = useState<HTMLDivElement | null>(null);
  if (!entry.pick) return null;
  return (
    <div ref={setContainer}>
      <UiProvider container={container} dir={languageDirection(locale)}>
        <RecordedVariantPick
          key={entry.id}
          context={{ entryId: entry.id }}
          beads={beadsPickSink(entry.pick.beadId)}
          recommendedId={entry.pick.recommendedId}
          strings={variantPickStrings([locale])}
          options={Object.keys(entry.variants).map((id) => ({ id, label: id, preview: preview(id) }))}
        />
      </UiProvider>
    </div>
  );
}
