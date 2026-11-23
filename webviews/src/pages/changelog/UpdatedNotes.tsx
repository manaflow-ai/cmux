// The "cmux Updated!" card's changes beside the sidebar (`#/surface/updated-notes`, the shipped
// look, updatedPreviewMode.ts): the native card host opens this page in the app's one hover card
// window, menu-wide, to the side of the sidebar, as the staged update card's highlights open. The
// card itself never grows.
//
// Lawrence 2026-11-07, on the list that grew up out of the bottom card over the sidebar's rows: "i
// dont like how it expands upwards, also it looks very bad". A calm header (what the app updated
// to, the full version, What's New), a hairline, then each change: its title whole, on as many
// lines as it needs, and a quiet detail under it (titles alone in the `beside-titles` look).
//
// Leo 2026-11-08: "the sections should be more obvious what's what ... distinguishing which row does
// what is unclear. therefore it is also unclear whether you can even scroll down and why you should
// ... if someone clicks it... maybe just bring them to the section in what's new aka bringing that tab
// up". The changes stand under What's New's own area headers (its glyph, name and count, in its
// order), each change is one pill, a count at the bottom says how many more are below while there
// are, and a click opens What's New at that change.
//
// Leo 2026-11-14, on the popover's blobby cloud, its icon-less Other and rows like "Redesign Cloud
// connection gates with human targets": "theese are kinda crappy looking icons and stuff", then, with
// Claude Code's What's New sheet: "here's how claude code does some of their what's new for example".
// The `release` look ships: the changes under New, Improved and Fixed labels in small capitals, one
// plain sentence per bullet (readableChange.ts plainChange), the version a quiet mono chip, and what
// no person sees folded into one "Maintenance and fixes" line. The area looks draw each area's symbol
// from the app's own set (SheetPage.tsx AREA_SYMBOLS) on one grid column with its name and count.
import { useEffect, useId, useRef, useState } from "react";
import { CARD_SCROLL_ATTRIBUTE, installScrollEdges } from "../../scrollers";
import { useDecoration } from "../../theme/decorations";
import type { Strings } from "../shared/i18n";
import type { ReleaseNotes } from "./types";
import type { UpdateHighlights, UpdateSurfaceActions } from "./updateHighlights";
import { Icon } from "../settings/icons";
import { AreaIcon } from "./SheetPage";
import type { WhatsNewCategory } from "./types";
import { plainEntries, previewEntries, previewSections, type PreviewEntry } from "./updatedPreview";
import { ChipNotes, DigestNotes, HeadlineNotes, LedgerNotes, NotesRow } from "./UpdatedNotesLooks";
import { parsePreviewMode, type UpdatedPreviewMode } from "./updatedPreviewMode";
import { CopyVersion } from "./UpdateSurfaces";
import { GoBack, GoBackHeaderLink, type GoBackLook } from "./GoBack";

/** How the changes stand (`sections` ships): under their areas' headers with a gap between pills
    (`sections`), under the headers with hairlines between rows (`divided`, gallery), one flat list
    (`flat`, the look before, gallery), or one of the Debug looks (UpdatedNotesLooks.tsx: `digest`,
    `chips`, `headline`, `ledger`; Debug Settings `sidebar.updatedCard.notesLook`). */
export type NotesLook = "release" | "sections" | "divided" | "flat" | "digest" | "chips" | "headline" | "ledger";

const LOOKS: readonly NotesLook[] = ["release", "sections", "divided", "flat", "digest", "chips", "headline", "ledger"];

/** How an area look's headers draw their symbol: in the label's own quiet color (`mono`), or in the
    theme's accent as What's New's page does (`accent`, gallery). */
export type NotesHead = "mono" | "accent";

/** The look the theme's `updated-notes-look` slot names; `release` without one or for a name it does not know. */
export function parseNotesLook(value: string | null | undefined): NotesLook {
  return LOOKS.find((look) => look === value) ?? "release";
}

/** The kinds the `release` look heads its changes with, in this order. */
const KINDS: readonly WhatsNewCategory[] = ["new", "improved", "fixed", "security"];

export function UpdatedNotes({
  data,
  span,
  strings,
  actions,
  mode,
  look: lookProp,
  goBackLook = "footer",
  goBackFixture,
  head = "mono",
}: {
  data: UpdateHighlights;
  /** The notes of every build the update spans, newest first; absent until they load. */
  span?: ReleaseNotes[];
  strings: Strings;
  actions: UpdateSurfaceActions;
  /** The card's look (gallery); undefined reads the theme's. */
  mode?: UpdatedPreviewMode;
  /** How the changes stand (gallery); undefined reads the theme's. */
  look?: NotesLook;
  /** Where the way back to an earlier build stands (GoBack.tsx; gallery); `footer` ships. */
  goBackLook?: GoBackLook;
  /** The way back's props held for a gallery still. */
  goBackFixture?: Pick<Parameters<typeof GoBack>[0], "builds" | "open" | "state">;
  /** How an area look's headers draw their symbol (gallery). */
  head?: NotesHead;
}) {
  const themedLook = parseNotesLook(useDecoration("updated-notes-look"));
  const look = lookProp ?? themedLook;
  const titleId = useId();
  const themed = parsePreviewMode(useDecoration("updated-card-preview"));
  const titlesOnly = (mode ?? themed) === "beside-titles";
  const [copied, setCopied] = useState(false);
  const scroller = useRef<HTMLElement | null>(null);
  const { entries, maintenance } = plainEntries(previewEntries(data, span, strings.language), strings.language);
  useEffect(() => (scroller.current ? installScrollEdges(scroller.current) : undefined), [entries.length]);
  const below = useRowsBelow(scroller, entries.length, look);
  const name = /^[^-]+-nightly\.\d+$/.test(data.version) ? strings.t("updates.card.nightly") : data.version;
  const titleKey = data.delivery === "background" ? "updates.card.updatedBehind" : "updates.card.updatedTo";
  const [before, after] = strings.format(titleKey, "\u0000").split("\u0000");
  return (
    <section
      className="wn-notes"
      data-look={look}
      data-titles={titlesOnly ? "" : undefined}
      aria-labelledby={titleId}
      ref={scroller}
      {...{ [CARD_SCROLL_ATTRIBUTE]: "" }}
    >
      <header className="wn-notes-head">
        <div className="wn-notes-title" id={titleId}>
          {before}
          {name}
          {after}
        </div>
        <span className="wn-notes-links">
          {goBackLook === "header" && <GoBackHeaderLink goBack={data.goBack} strings={strings} actions={actions} />}
          <button type="button" className="wn-notes-whatsnew" onClick={() => actions.openChangelog()}>
            {strings.t("changelog.page.title")}
            <span aria-hidden="true"> ↗</span>
          </button>
        </span>
        {/* The full version under the title, unless the title already says it (a release). */}
        {name !== data.version && (
          <div className="wn-notes-version">
            <CopyVersion version={data.version} strings={strings} onCopied={setCopied}>
              {data.version}
            </CopyVersion>
            <span aria-live="polite">{copied && ` · ${strings.t("updates.card.copied")}`}</span>
          </div>
        )}
      </header>
      {(entries.length > 0 || maintenance > 0) && look === "release" && (
        <ReleaseList
          entries={entries}
          maintenance={maintenance}
          titlesOnly={titlesOnly}
          strings={strings}
          actions={actions}
        />
      )}
      {entries.length > 0 && look === "digest" && (
        <DigestNotes entries={entries} titlesOnly={titlesOnly} strings={strings} actions={actions} />
      )}
      {entries.length > 0 && look === "chips" && (
        <ChipNotes entries={entries} titlesOnly={titlesOnly} strings={strings} actions={actions} />
      )}
      {entries.length > 0 && look === "headline" && (
        <HeadlineNotes entries={entries} titlesOnly={titlesOnly} strings={strings} actions={actions} />
      )}
      {entries.length > 0 && look === "ledger" && <LedgerNotes entries={entries} strings={strings} actions={actions} />}
      {entries.length > 0 && (look === "sections" || look === "divided" || look === "flat") && (
        <ul className="wn-notes-list" data-look={look} data-head={head} aria-label={strings.t("changelog.page.title")}>
          {look === "flat"
            ? entries.map((entry) => (
                <NotesRow key={entry.id} entry={entry} titlesOnly={titlesOnly} actions={actions} />
              ))
            : previewSections(entries).map((section) => {
                const label = section.area
                  ? strings.t(`updates.area.${section.area}`)
                  : strings.t("changelog.page.otherArea");
                return (
                  <li key={section.area ?? "other"} className="wn-notes-section" data-area={section.area ?? "other"}>
                    <h3 className="wn-notes-area">
                      <span className="wn-notes-area-icon" aria-hidden="true">
                        <AreaIcon area={section.area} />
                      </span>
                      <span className="wn-notes-area-name">{label}</span>
                      <span className="wn-notes-area-count">{section.items.length}</span>
                    </h3>
                    <ul className="wn-notes-rows" aria-label={label}>
                      {section.items.map((entry) => (
                        <NotesRow key={entry.id} entry={entry} titlesOnly={titlesOnly} actions={actions} />
                      ))}
                    </ul>
                  </li>
                );
              })}
          {look !== "flat" && maintenance > 0 && (
            <li className="wn-notes-section" data-area="maintenance">
              <button
                type="button"
                className="wn-notes-area wn-notes-maintenance"
                onClick={() => actions.openChangelog()}
              >
                <span className="wn-notes-area-icon" aria-hidden="true">
                  <Icon name="hammer" className="area-symbol" />
                </span>
                <span className="wn-notes-area-name">{strings.t("changelog.page.maintenance")}</span>
                <span className="wn-notes-area-count">{maintenance}</span>
              </button>
            </li>
          )}
        </ul>
      )}
      {below > 0 && (
        <div className="wn-notes-more" aria-hidden="true">
          <svg viewBox="0 0 12 12" width="12" height="12">
            <path d="M3 4.5 6 7.5 9 4.5" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
          </svg>
          {strings.format("updates.card.more", String(below))}
        </div>
      )}
      {goBackLook !== "header" && (
        <GoBack
          goBack={data.goBack}
          running={data.goBackRunning === true}
          strings={strings}
          actions={actions}
          look={goBackLook}
          {...goBackFixture}
        />
      )}
    </section>
  );
}

/** `release`: the changes under New, Improved and Fixed in small capitals, one bullet each, then how
    many changes no person sees, as one quiet line (Leo's Claude Code reference, 2026-11-14). */
function ReleaseList({
  entries,
  maintenance,
  titlesOnly,
  strings,
  actions,
}: {
  entries: PreviewEntry[];
  maintenance: number;
  titlesOnly: boolean;
  strings: Strings;
  actions: UpdateSurfaceActions;
}) {
  const kinds = KINDS.map((kind) => ({
    kind,
    items: entries.filter((entry) => (entry.category ?? "improved") === kind),
  })).filter((group) => group.items.length > 0);
  return (
    <div className="wn-notes-list" data-look="release" aria-label={strings.t("changelog.page.title")}>
      {kinds.map(({ kind, items }) => {
        const label = strings.t(`changelog.group.${kind}`);
        return (
          <section key={kind} className="wn-notes-kind" data-kind={kind} aria-label={label}>
            <h3 className="wn-notes-kind-label">{label}</h3>
            <ul className="wn-notes-rows">
              {items.map((entry) => (
                <NotesRow key={entry.id} entry={entry} titlesOnly={titlesOnly} actions={actions} />
              ))}
            </ul>
          </section>
        );
      })}
      {maintenance > 0 && (
        <button type="button" className="wn-notes-maintenance-line" onClick={() => actions.openChangelog()}>
          {strings.t("changelog.page.maintenance")}
          <span className="wn-notes-area-count">{maintenance}</span>
        </button>
      )}
    </div>
  );
}

/** How many rows stand past the scroller's bottom edge (more than half hidden), kept current as the
    list scrolls and as its rows or the popover change size. */
function useRowsBelow(scroller: { current: HTMLElement | null }, count: number, look: NotesLook): number {
  const [below, setBelow] = useState(0);
  useEffect(() => {
    const element = scroller.current;
    if (!element) return undefined;
    const recount = () => {
      const bottom = element.getBoundingClientRect().bottom;
      let hidden = 0;
      for (const row of element.querySelectorAll<HTMLElement>(".wn-notes-row")) {
        const rect = row.getBoundingClientRect();
        if (rect.top + rect.height / 2 > bottom) hidden++;
      }
      setBelow(hidden);
    };
    recount();
    element.addEventListener("scroll", recount, { passive: true });
    const resize = typeof ResizeObserver === "function" ? new ResizeObserver(recount) : undefined;
    resize?.observe(element);
    const list = element.querySelector(".wn-notes-list");
    if (list) resize?.observe(list);
    return () => {
      element.removeEventListener("scroll", recount);
      resize?.disconnect();
    };
  }, [scroller, count, look]);
  return below;
}
