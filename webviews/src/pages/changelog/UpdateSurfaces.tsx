// The update surfaces of the What's New system (cx-urd.61, Lawrence picked card A and popover A,
// 2026-10-11), in the same tokens and type steps as the changelog page:
//  - UpdatedCard (after an update, the sidebar's bottom card slot): the composer's surface, as every
//    sidebar card (Leo 2026-10-13), a quiet eyebrow with the short version ("Updated to nightly
//    3845050"), the update's top changes listed one line each (u2441, gallery #01 "Compact list",
//    2026-10-19; else "What's new in this build"), the count of the changes not listed and one
//    button on one row. The x shows only on hover or keyboard focus. Share cmux is the palette's
//    (app.shareCmux).
//  - UpdateReadyHighlights (hovering the staged "Restart to Update" card): only what the card lacks
//    (Leo 2026-10-13; the card has Update Ready, the short version and the date): a quiet "What's
//    new in nightly 3845050" (the full build in its tooltip, Leo 2026-10-19), the top three changes
//    numbered, each a title, one line and its picture when it has one, and "See all changes", once.
// Data: UpdateHighlights (updateHighlights.ts); the host mounts these and wires the actions.
import { useId, useSyncExternalStore } from "react";
import { getColorScheme, subscribeColorScheme } from "./colorScheme";
import { distinctSummary } from "./model";
import type { Strings } from "../shared/i18n";
import type { UpdateHighlightMedia, UpdateHighlights, UpdateSurfaceActions } from "./updateHighlights";

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
      {data.items.length > 0 ? (
        <ul className="wn-card-changes">
          {data.items.map((item) => (
            <li key={item.id} title={item.title}>
              {item.title}
            </li>
          ))}
        </ul>
      ) : (
        <div className="wn-card-headline">{strings.t("updates.card.whatsNewInBuild")}</div>
      )}
      <div className="wn-card-actions">
        {data.items.length > 0 && data.moreCount > 0 && (
          <span className="wn-card-more">{strings.format("updates.card.more", String(data.moreCount))}</span>
        )}
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
      <div className="wn-pop-title" id={titleId} title={data.version}>
        {strings.format("updates.popover.title", cardVersion(data.version))}
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
                {item.media && <PopMedia media={item.media} onOpen={actions.openChangelog} />}
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

/** A change's picture at the popover's width, in the theme's scheme; a click opens the change's
 * notes, where it shows at the page's width. Only `data:` pictures reach it (the host inlines
 * and checks each file, ReleaseMediaStore). */
function PopMedia({ media, onOpen }: { media: UpdateHighlightMedia; onOpen: () => void }) {
  const scheme = useSyncExternalStore(subscribeColorScheme, getColorScheme, () => "light" as const);
  const src = scheme === "dark" ? media.dark : media.light;
  // Anything but an inlined picture (a remote or relative URL) never loads here.
  if (!src.startsWith("data:image/")) return null;
  return (
    <button type="button" className="wn-pop-media" onClick={onOpen} aria-label={media.alt}>
      <img key={src} src={src} alt="" decoding="async" />
    </button>
  );
}
