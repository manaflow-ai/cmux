// l10n-allow-file: gallery design fixtures for where the repo tour offer sits, not shipped UI.
// Three places for the first-open tour offer, side by side in the gallery. Only `line` ships
// (EmptyState's TourOffer under the question); `row` and `card` exist here alone, around the real
// hero, so the choice is made on what each looks like.
import { EmptyState } from "../EmptyState";
import { translate as t } from "../i18n";
import { TourGlyph } from "./TourCard";
import { TourOffer } from "./TourOffer";
import "./tourOfferDesigns.css";

/// `line`: one quiet line under the hero's question (shipped). `row`: a suggestion row just above
/// the composer. `card`: a card in the hero with a one-line why and a button.
export type TourOfferDesign = "line" | "row" | "card";

const noop = () => undefined;

export function TourOfferDesigns({ design, project = "atlas-web" }: { design: TourOfferDesign; project?: string }) {
  return (
    <div className="tour-designs">
      <div className="tour-designs-hero">
        {design === "line" ? (
          <EmptyState project={project} tour={{ onTake: noop, onDismiss: noop }} />
        ) : (
          <EmptyState project={project} />
        )}
        {design === "card" && (
          <div className="tour-designs-card">
            <TourGlyph size={20} />
            <div className="tour-designs-card-text">
              <strong>{t("tour.offer")}</strong>
              <span>What it is, its main modules, how to run it and three first tasks.</span>
            </div>
            <button type="button" className="acpmux-tour-start">
              {t("tour.start")}
            </button>
          </div>
        )}
      </div>
      {design === "row" && (
        <div className="tour-designs-row">
          <TourOffer onTake={noop} onDismiss={noop} />
        </div>
      )}
      <div className="tour-designs-composer">Ask anything</div>
    </div>
  );
}
