// The update surfaces of the What's New system (cx-urd.61, Lawrence picked card A and popover A,
// 2026-10-11), in the same tokens and type steps as the changelog page:
//  - UpdatedCard (after an update, the sidebar's bottom card slot): the composer's surface, as every
//    sidebar card (Leo 2026-10-13), a quiet eyebrow with the version and date in words ("Updated to
//    Nightly · Oct 20", the full build in its tooltip; Lawrence 2026-10-20), then what changed since
//    the previous version, one line per area ("Sidebar: …; …", updateSummary.ts; it was the newest
//    commit's subject alone, 2026-10-20), the count of the changes not listed and one button on one
//    row. An update with nothing a person would notice says "Maintenance and fixes"; "What's new in
//    this build" is the last resort while nothing is known. The x shows only on hover or keyboard
//    focus; in the sidebar the host draws it natively (SidebarUpdatedCardHost) and Escape closes it. A change has no tooltip, even cut off (Leo 2026-10-19: no hover preview on change
//    titles). Share cmux is the palette's (app.shareCmux).
//  - UpdateReadyHighlights (hovering the staged "Restart to Update" card): only what the card lacks
//    (Leo 2026-10-13; the card has Update Ready, the short version and the date): a quiet "What's
//    new in nightly 3845050" (the full build in its tooltip, Leo 2026-10-19), the top three changes
//    numbered, each a title, one line and its picture when it has one, and "See all changes", once.
//    The popover scrolls on to every other change of the update (`rest`, 2026-10-20), with the
//    shared card scroller and a fade at each edge that has more past it (scrollers.ts).
//    Under the title, the version it replaces ("Updating from nightly 3801702", Lawrence 2026-10-19:
//    show at once what is going to change); with no change list, "See release notes" instead.
// Data: UpdateHighlights (updateHighlights.ts); the host mounts these and wires the actions.
import { useEffect, useId, useRef, useSyncExternalStore } from "react";
import { CARD_SCROLL_ATTRIBUTE, installScrollEdges } from "../../scrollers";
import { getColorScheme, subscribeColorScheme } from "./colorScheme";
import { distinctSummary } from "./model";
import type { Strings } from "../shared/i18n";
import type { ReleaseNotes } from "./types";
import type { UpdateHighlightMedia, UpdateHighlights, UpdateSurfaceActions } from "./updateHighlights";
import { summarizeHighlights, summarizeUpdate, type SummaryRow } from "./updateSummary";

/** "1.0.0-nightly.3845050428001" reads "nightly 3845050", as the native Update Ready card
 * (UpdateChangelog.cardVersion): every nightly is 1.0.0. Any other version reads as itself. */
export function cardVersion(version: string): string {
  const match = /^[^-]+-nightly\.(\d+)$/.exec(version);
  return match ? `nightly ${match[1]!.slice(0, 7)}` : version;
}

/** The Updated card's version in words (2026-10-20, Lawrence: "not descriptive enough at all"):
 * "Nightly · Oct 20" for a nightly, "1.2.0 · Oct 20" for a release; the date is the build's, in the
 * page's language. The raw build stays in the eyebrow's tooltip. */
export function cardLabel(version: string, date: string | null | undefined, strings: Strings): string {
  const name = /^[^-]+-nightly\.\d+$/.test(version) ? strings.t("updates.card.nightly") : version;
  const day = date ? readableDay(date, strings.language) : null;
  return day ? `${name} · ${day}` : name;
}

/** "2026-10-20" as "Oct 20" in `language`; null when it is not a date. */
function readableDay(date: string, language: string): string | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
  if (!match) return null;
  const day = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])));
  try {
    return new Intl.DateTimeFormat(language, { month: "short", day: "numeric", timeZone: "UTC" }).format(day);
  } catch {
    return new Intl.DateTimeFormat("en", { month: "short", day: "numeric", timeZone: "UTC" }).format(day);
  }
}

export function UpdatedCard({
  data,
  span,
  strings,
  actions,
  closeButton = true,
}: {
  data: UpdateHighlights;
  /** The notes of every build after the previous version, newest first; absent until they load. */
  span?: ReleaseNotes[];
  strings: Strings;
  actions: UpdateSurfaceActions;
  /** Draws the x (with `actions.dismiss`); false where the host draws its own (the sidebar's). */
  closeButton?: boolean;
}) {
  const titleId = useId();
  const summary = span ? summarizeUpdate(span, strings.language) : summarizeHighlights(data);
  const empty = strings.t(span ? "changelog.page.maintenance" : "updates.card.whatsNewInBuild");
  return (
    <section className="ui-glass wn-card" aria-labelledby={titleId}>
      {/* tooltip-allow: the eyebrow says the version in words; the tooltip names the full build. */}
      <div className="wn-card-eyebrow" id={titleId} title={data.version}>
        {strings.format("updates.card.updatedTo", cardLabel(data.version, data.date, strings))}
      </div>
      {closeButton && actions.dismiss && (
        <button
          type="button"
          className="wn-card-close"
          aria-label={strings.t("updates.card.dismiss")}
          onClick={actions.dismiss}
        >
          <svg viewBox="0 0 10 10" aria-hidden="true">
            <path d="M2 2l6 6M8 2l-6 6" />
          </svg>
        </button>
      )}
      {summary.rows.length > 0 ? (
        <ul className="wn-card-areas">
          {summary.rows.map((row) => (
            <li key={row.area ?? row.category}>
              <span className="wn-card-area">{strings.format("updates.card.areaLabel", rowLabel(row, strings))}</span>{" "}
              <span className="wn-card-phrases">{row.phrases.join(strings.t("updates.card.phraseJoiner"))}</span>
            </li>
          ))}
        </ul>
      ) : (
        <div className="wn-card-headline">{empty}</div>
      )}
      <div className="wn-card-actions">
        {summary.rows.length > 0 && summary.more > 0 && (
          <span className="wn-card-more">{strings.format("updates.card.more", String(summary.more))}</span>
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
  const scroller = useRef<HTMLElement>(null);
  const rest = data.rest ?? null;
  useEffect(() => (scroller.current ? installScrollEdges(scroller.current) : undefined), [data]);
  return (
    <section className="wn-pop" aria-labelledby={titleId} ref={scroller} {...{ [CARD_SCROLL_ATTRIBUTE]: "" }}>
      {/* tooltip-allow: the heading shows the short version; the tooltip names the full build (Leo 2026-10-19). */}
      <div className="wn-pop-title" id={titleId} title={data.version}>
        {strings.format("updates.popover.title", cardVersion(data.version))}
      </div>
      {data.fromVersion && data.fromVersion !== data.version && (
        <div className="wn-pop-from">{strings.format("updates.popover.from", cardVersion(data.fromVersion))}</div>
      )}
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
      {rest && rest.length > 0 && (
        <div className="wn-pop-rest">
          {REST_ORDER.map((category) => {
            const items = rest.filter((item) => item.category === category);
            if (items.length === 0) return null;
            return (
              <section
                key={category}
                className="wn-pop-rest-group"
                aria-label={strings.t(`changelog.group.${category}`)}
              >
                <h4>{strings.t(`changelog.group.${category}`)}</h4>
                <ul>
                  {items.map((item) => (
                    <li key={item.id}>{item.title}</li>
                  ))}
                </ul>
              </section>
            );
          })}
        </div>
      )}
      <div className="wn-pop-foot">
        {!rest && data.moreCount > 0 && (
          <span className="wn-pop-more">{strings.format("updates.card.more", String(data.moreCount))}</span>
        )}
        <button type="button" className="wn-pop-all" onClick={actions.openChangelog}>
          {strings.t(data.items.length > 0 ? "updates.popover.seeAll" : "updates.popover.seeReleaseNotes")}
          <span aria-hidden="true"> →</span>
        </button>
      </div>
    </section>
  );
}

/** A row's name: the area ("Sidebar"), else the category its changes share ("Fixed"). */
function rowLabel(row: SummaryRow, strings: Strings): string {
  return row.area ? strings.t(`updates.area.${row.area}`) : strings.t(`changelog.group.${row.category ?? "improved"}`);
}

/** The rest of an update reads as Conductor's release pages do: New, Improved, Fixed, Security. */
const REST_ORDER = ["new", "improved", "fixed", "security"] as const;

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
