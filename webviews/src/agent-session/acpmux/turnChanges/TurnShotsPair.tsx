// The edited-files card's before and after picture of the chat's page (turnShots.ts): the shared
// pair (ui/MediaCompare.tsx) the person drags or moves with the arrow keys, and Open full size,
// which shows the after picture in the chat's image viewer. Nothing draws until the pair is read,
// and a turn with no pair draws nothing. A pair that arrives while the card shows grows in through
// the motion gate; one read before (the card scrolled back into view) draws at once.
import { useContext, useEffect, useState } from "react";
import { MediaCompare } from "../../../ui/MediaCompare";
import { ImageViewerContext } from "../conversation/imageViewerContext";
import { useT } from "../i18n";
import { TurnShotsContext } from "./turnShots";

export function TurnShots({ rowId }: { rowId: string }) {
  const reader = useContext(TurnShotsContext);
  const openImage = useContext(ImageViewerContext);
  const t = useT();
  // The row whose pair was read while this card showed: it grows in once; a pair read before draws
  // at once.
  const [arrived, setArrived] = useState<string>();
  useEffect(() => {
    if (!reader || reader.peek(rowId)) return;
    let live = true;
    void reader.read(rowId).then(() => {
      if (live) setArrived(rowId);
    });
    return () => {
      live = false;
    };
  }, [reader, rowId]);
  const pair = reader?.peek(rowId)?.pair;
  if (!pair) return null;
  const labels = {
    before: t("turnShots.before"),
    after: t("turnShots.after"),
    drag: t("turnShots.drag"),
    show: t("turnShots.show"),
  };
  const afterAlt = t("turnShots.alt.after");
  return (
    <div className="acpmux-turn-shots" data-arrived={arrived === rowId ? "" : undefined}>
      <div className="acpmux-turn-shots-frame">
        <MediaCompare
          after={{ src: pair.after, alt: afterAlt }}
          before={{ src: pair.before, alt: t("turnShots.alt.before") }}
          labels={labels}
          mode={reader?.mode}
          loading="eager"
        />
        {openImage && (
          <button
            type="button"
            className="acpmux-turn-shots-open ui-glass"
            aria-label={t("turnShots.open")}
            title={t("turnShots.open")}
            onClick={() => openImage(pair.after, afterAlt)}
          >
            <svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true">
              <path d="M9.5 2.5h4v4M13.5 2.5 9 7M6.5 13.5h-4v-4M2.5 13.5 7 9" />
            </svg>
          </button>
        )}
      </div>
    </div>
  );
}
