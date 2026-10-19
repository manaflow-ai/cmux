// The update surfaces of the What's New system (cx-urd.61, Lawrence picked card A and popover A,
// 2026-10-11), in the same tokens and type steps as the changelog page:
//  - UpdatedCard (after an update, the sidebar's bottom card slot): the composer's surface, as every
//    sidebar card (Leo 2026-10-13), a quiet eyebrow with the short version ("Updated to nightly
//    3845050"), the update's lead change as its headline (else "What's new in this build"), how
//    many more changes came with it, and one button. Share cmux is the palette's (app.shareCmux).
//  - UpdateReadyHighlights (hovering the staged "Restart to Update" card): only what the card lacks
//    (Leo 2026-10-13; the card has Update Ready, the short version and the date): the full build,
//    the top three changes numbered, each a title and one line, and "See all changes", once.
// Data: UpdateHighlights (updateHighlights.ts); the host mounts these and wires the actions.
import { useId } from "react";
import { distinctSummary } from "./model";
import type { Strings } from "../shared/i18n";
import type { UpdateHighlights, UpdateSurfaceActions } from "./updateHighlights";

/** "1.0.0-nightly.3845050428001" reads "nightly 3845050", as the native Update Ready card
 * (UpdateChangelog.cardVersion): every nightly is 1.0.0. Any other version reads as itself. */
export function cardVersion(version: string): string {
  const match = /^[^-]+-nightly\.(\d+)$/.exec(version);
  return match ? `nightly ${match[1]!.slice(0, 7)}` : version;
}

export function UpdatedCard({
  data,
  strings,
  actions,
}: {
  data: UpdateHighlights;
  strings: Strings;
  actions: UpdateSurfaceActions;
}) {
  const [lead] = data.items;
  const more = data.items.length - 1 + data.moreCount;
  const titleId = useId();
  return (
    <section className="wn-card" aria-labelledby={titleId}>
      <div className="wn-card-eyebrow" id={titleId}>
        {strings.format("updates.card.updatedTo", cardVersion(data.version))}
      </div>
      {actions.dismiss && (
        <button
          type="button"
          className="wn-card-close"
          aria-label={strings.t("updates.card.dismiss")}
          title={strings.t("updates.card.dismiss")}
          onClick={actions.dismiss}
        >
          <svg viewBox="0 0 10 10" aria-hidden="true">
            <path d="M2 2l6 6M8 2l-6 6" />
          </svg>
        </button>
      )}
      <div className="wn-card-headline">{lead ? lead.title : strings.t("updates.card.whatsNewInBuild")}</div>
      {lead && more > 0 && <div className="wn-card-line">{strings.format("updates.card.more", String(more))}</div>}
      <div className="wn-card-actions">
        <button type="button" className="wn-card-primary" onClick={actions.openChangelog}>
          {strings.t("updates.card.seeWhatsNew")}
        </button>
      </div>
    </section>
  );
}

export function UpdateReadyHighlights({
  data,
  strings,
  actions,
}: {
  data: UpdateHighlights;
  strings: Strings;
  actions: UpdateSurfaceActions;
}) {
  const titleId = useId();
  return (
    <section className="wn-pop" aria-labelledby={titleId}>
      <div className="wn-pop-title" id={titleId}>
        {data.version}
      </div>
      {data.items.length > 0 && (
        <ol className="wn-pop-list">
          {data.items.map((item, index) => (
            <li key={item.id}>
              <span className="wn-pop-n" aria-hidden="true">
                {index + 1}
              </span>
              <div>
                <span className="wn-pop-item">{item.title}</span>
                {item.summary && distinctSummary(item.title, item.summary) && (
                  <span className="wn-pop-line">{item.summary}</span>
                )}
              </div>
            </li>
          ))}
        </ol>
      )}
      <div className="wn-pop-foot">
        {data.moreCount > 0 && (
          <span className="wn-pop-more">{strings.format("updates.card.more", String(data.moreCount))}</span>
        )}
        <button type="button" className="wn-pop-all" onClick={actions.openChangelog}>
          {strings.t("updates.popover.seeAll")}
          <span aria-hidden="true"> →</span>
        </button>
      </div>
    </section>
  );
}
