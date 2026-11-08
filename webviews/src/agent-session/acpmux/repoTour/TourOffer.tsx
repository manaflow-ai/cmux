// The tour offer on a new chat's hero (EmptyState.tsx): one quiet line under the question, in a
// folder no chat has used yet (tourModel.ts offersTour). Never run by itself: Take the tour sends
// the tour prompt; the × closes it for this folder. It hangs below the question, out of the hero's
// flow, so its arrival never moves the question, and it fades in (none under Reduce Motion).
import { useT } from "../i18n";
import { TourGlyph } from "./TourCard";
import "./tour.css";

export type TourOfferActions = { onTake(): void; onDismiss(): void };

export function TourOffer({ onTake, onDismiss }: TourOfferActions) {
  const t = useT();
  return (
    <div className="acpmux-tour-offer">
      <button type="button" className="acpmux-tour-offer-take" onClick={onTake}>
        <TourGlyph />
        <span>{t("tour.offer")}</span>
      </button>
      <button
        type="button"
        className="acpmux-tour-offer-dismiss"
        onClick={onDismiss}
        aria-label={t("tour.dismiss")}
        title={t("tour.dismiss")}
      >
        <svg width={10} height={10} viewBox="0 0 10 10" aria-hidden="true" focusable="false">
          <path d="m2 2 6 6M8 2 2 8" stroke="currentColor" strokeWidth={1.25} strokeLinecap="round" />
        </svg>
      </button>
    </div>
  );
}
