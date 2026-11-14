// The other ways the Updated card's changes can stand in the popover beside the sidebar (Debug
// Settings `sidebar.updatedCard.notesLook`, UpdatedNotesLook.swift). Lawrence 2026-11-09, on the
// popover ("Updated to Nightly", the Agent Chat list, "+162 more"): "make and show me more versions
// of this ui". Each look answers one question differently; `sections` (UpdatedNotes.tsx) ships until
// one is picked:
//
// - `digest` (density): one line per area, its count and first titles; a click opens the area here.
// - `chips` (interaction): the areas as filter chips over one list of the changes.
// - `headline` (hierarchy): the update's first few changes at full size, then one way to the rest.
// - `ledger` (scan): one line per change, its area as a quiet label beside it; no headers.
//
// Every row keeps the `wn-notes-row` class, so the "+N more" count reads every look the same way.
import { useState } from "react";
import type { Strings } from "../shared/i18n";
import type { AreaKey } from "./areas";
import { AreaIcon } from "./SheetPage";
import type { UpdateSurfaceActions } from "./updateHighlights";
import { previewSections, type PreviewEntry } from "./updatedPreview";

/** How many changes the `headline` look shows at full size. */
export const HEADLINE_COUNT = 3;
/** How many titles a closed `digest` area names. */
const DIGEST_PEEK = 2;

function areaLabel(area: AreaKey | undefined, strings: Strings): string {
  return area ? strings.t(`updates.area.${area}`) : strings.t("changelog.page.otherArea");
}

/** One change as a pill: its title and detail; a click opens What's New at it. */
export function NotesRow({
  entry,
  titlesOnly,
  actions,
}: {
  entry: PreviewEntry;
  titlesOnly: boolean;
  actions: UpdateSurfaceActions;
}) {
  return (
    <li>
      <button
        type="button"
        className="wn-notes-row"
        onClick={() => actions.openChangelog({ area: entry.area, title: entry.title })}
      >
        <span className="wn-notes-row-title">{entry.title}</span>
        {!titlesOnly && entry.detail && <span className="wn-notes-row-detail">{entry.detail}</span>}
      </button>
    </li>
  );
}

/** `digest`: each area on one line, closed; open, its changes as pills under it. */
export function DigestNotes({
  entries,
  titlesOnly,
  strings,
  actions,
}: {
  entries: PreviewEntry[];
  titlesOnly: boolean;
  strings: Strings;
  actions: UpdateSurfaceActions;
}) {
  const [open, setOpen] = useState<ReadonlySet<string>>(() => new Set());
  const toggle = (key: string) =>
    setOpen((current) => {
      const next = new Set(current);
      if (!next.delete(key)) next.add(key);
      return next;
    });
  return (
    <ul className="wn-notes-list" data-look="digest" aria-label={strings.t("changelog.page.title")}>
      {previewSections(entries).map((section) => {
        const key = section.area ?? "other";
        const label = areaLabel(section.area, strings);
        const shown = open.has(key);
        const peek = section.items.slice(0, DIGEST_PEEK).map((entry) => entry.title);
        return (
          <li key={key} className="wn-notes-digest" data-area={key} data-open={shown ? "" : undefined}>
            <button type="button" className="wn-notes-digest-head" aria-expanded={shown} onClick={() => toggle(key)}>
              <span className="wn-notes-area-icon" aria-hidden="true">
                <AreaIcon area={section.area} />
              </span>
              <span className="wn-notes-digest-text">
                <span className="wn-notes-digest-name">
                  {label}
                  <span className="wn-notes-area-count">{section.items.length}</span>
                </span>
                {!shown && <span className="wn-notes-digest-peek">{peek.join(" · ")}</span>}
              </span>
              <svg className="wn-notes-digest-chevron" viewBox="0 0 12 12" width="12" height="12" aria-hidden="true">
                <path
                  d="M4.5 3 7.5 6 4.5 9"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="1.4"
                  strokeLinecap="round"
                />
              </svg>
            </button>
            {shown && (
              <ul className="wn-notes-rows" aria-label={label}>
                {section.items.map((entry) => (
                  <NotesRow key={entry.id} entry={entry} titlesOnly={titlesOnly} actions={actions} />
                ))}
              </ul>
            )}
          </li>
        );
      })}
    </ul>
  );
}

/** `chips`: the areas as chips (All first); the list under them shows the chosen area's changes. */
export function ChipNotes({
  entries,
  titlesOnly,
  strings,
  actions,
}: {
  entries: PreviewEntry[];
  titlesOnly: boolean;
  strings: Strings;
  actions: UpdateSurfaceActions;
}) {
  const [chosen, setChosen] = useState<string | null>(null);
  const sections = previewSections(entries);
  const rows = chosen === null ? entries : (sections.find((s) => (s.area ?? "other") === chosen)?.items ?? []);
  return (
    <div className="wn-notes-chipped">
      <div className="wn-notes-chips" role="toolbar" aria-label={strings.t("changelog.page.title")}>
        <button type="button" className="wn-notes-chip" aria-pressed={chosen === null} onClick={() => setChosen(null)}>
          {strings.t("changelog.page.allChanges")}
          <span className="wn-notes-area-count">{entries.length}</span>
        </button>
        {sections.map((section) => {
          const key = section.area ?? "other";
          return (
            <button
              key={key}
              type="button"
              className="wn-notes-chip"
              aria-pressed={chosen === key}
              onClick={() => setChosen(chosen === key ? null : key)}
            >
              <span className="wn-notes-area-icon" aria-hidden="true">
                <AreaIcon area={section.area} />
              </span>
              {areaLabel(section.area, strings)}
              <span className="wn-notes-area-count">{section.items.length}</span>
            </button>
          );
        })}
      </div>
      <ul className="wn-notes-list wn-notes-rows" data-look="chips" aria-label={strings.t("changelog.page.title")}>
        {rows.map((entry) => (
          <NotesRow key={entry.id} entry={entry} titlesOnly={titlesOnly} actions={actions} />
        ))}
      </ul>
    </div>
  );
}

/** `headline`: the first changes at full size, each with its whole detail; then See all changes. */
export function HeadlineNotes({
  entries,
  titlesOnly,
  strings,
  actions,
}: {
  entries: PreviewEntry[];
  titlesOnly: boolean;
  strings: Strings;
  actions: UpdateSurfaceActions;
}) {
  const lead = entries.slice(0, HEADLINE_COUNT);
  const rest = entries.length - lead.length;
  return (
    <div className="wn-notes-headline">
      <ul className="wn-notes-list" data-look="headline" aria-label={strings.t("changelog.page.title")}>
        {lead.map((entry) => (
          <li key={entry.id}>
            <button
              type="button"
              className="wn-notes-row"
              onClick={() => actions.openChangelog({ area: entry.area, title: entry.title })}
            >
              <span className="wn-notes-headline-area">{areaLabel(entry.area, strings)}</span>
              <span className="wn-notes-row-title">{entry.title}</span>
              {!titlesOnly && entry.detail && <span className="wn-notes-headline-detail">{entry.detail}</span>}
            </button>
          </li>
        ))}
      </ul>
      {rest > 0 && (
        <button type="button" className="wn-notes-seeall" onClick={() => actions.openChangelog()}>
          <span>{strings.t("updates.popover.seeAll")}</span>
          <span className="wn-notes-area-count">{strings.format("updates.card.more", String(rest))}</span>
          <span aria-hidden="true">↗</span>
        </button>
      )}
    </div>
  );
}

/** `ledger`: one line per change, its area as a quiet label in a column beside it. */
export function LedgerNotes({
  entries,
  strings,
  actions,
}: {
  entries: PreviewEntry[];
  strings: Strings;
  actions: UpdateSurfaceActions;
}) {
  // In What's New's area order, so each area's label shows once, over its first change.
  const rows = previewSections(entries).flatMap((section) => section.items);
  return (
    <ul className="wn-notes-list" data-look="ledger" aria-label={strings.t("changelog.page.title")}>
      {rows.map((entry, index) => {
        const first = index === 0 || rows[index - 1]?.area !== entry.area;
        return (
          <li key={entry.id}>
            <button
              type="button"
              className="wn-notes-row"
              onClick={() => actions.openChangelog({ area: entry.area, title: entry.title })}
            >
              <span className="wn-notes-ledger-area" aria-hidden={!first}>
                {first ? areaLabel(entry.area, strings) : ""}
              </span>
              <span className="wn-notes-row-title">{entry.title}</span>
            </button>
          </li>
        );
      })}
    </ul>
  );
}
