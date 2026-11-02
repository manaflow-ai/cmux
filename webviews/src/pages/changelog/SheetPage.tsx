// The What's New sheet, the page's default design (Lawrence 2026-10-31, msg 19251: "what's new page
// looks bad, make many variations for me to pick from"; the default of cmux-shots/whatsnew-variations).
// Laid out as the What's New sheet of an Apple app: "What's New", then the release days newest first,
// each under its date, and each change one row: an icon for its kind (new, improved, fixed,
// security), its title in bold on one line and at most one muted line under it (its summary's first
// sentence, else the app area it is in). No version tags, build numbers, pull request chips or
// category headings: the Ledger (`design=ledger`) keeps them. A day with nothing a person would notice
// says "Maintenance and fixes". Days load as they near the viewport (JournalPage.loadNear); J and K
// move between them. The rows use the pane's width, dense (Leo 2026-11-01: "this is way too narrow
// and not info dense enough"): `layout` (the route's `sheet=`) sets them; styles.css .cls-inline.
import type { CSSProperties } from "react";
import { KeyboardScope } from "../../ui/KeyboardScope";
import type { Strings } from "../shared/i18n";
import { dayLabel, groupByDay, mergedView, type ReleaseView } from "./model";
import { journalKeys, loadNear } from "./JournalPage";
import { Maintenance } from "./ReleaseParts";
import type { ChangelogSnapshot, ChangelogStore } from "./store";
import type { IndexEntry, ReleaseNotes, SheetLayout, WhatsNewCategory } from "./types";

export function SheetPage({
  store,
  strings,
  s,
  layout = "inline",
}: {
  store: ChangelogStore;
  strings: Strings;
  s: ChangelogSnapshot;
  layout?: SheetLayout;
}) {
  return (
    <KeyboardScope className={`cls cls-${layout}`} handleKeyDown={journalKeys}>
      <main aria-labelledby="cls-title">
        <h1 className="cls-title" id="cls-title">
          {strings.t("changelog.page.title")}
        </h1>
        {s.failed && <p className="cl-error">{s.failed}</p>}
        {s.builds.length === 0 && !s.failed && <p className="cl-muted">{strings.t("changelog.page.noHistory")}</p>}
        {groupByDay(s.builds).map((day) => (
          <SheetDay
            key={day.day + day.builds[0]!.build}
            day={day.day}
            builds={day.builds}
            s={s}
            store={store}
            strings={strings}
          />
        ))}
      </main>
    </KeyboardScope>
  );
}

function SheetDay({
  day,
  builds,
  s,
  store,
  strings,
}: {
  day: string;
  builds: IndexEntry[];
  s: ChangelogSnapshot;
  store: ChangelogStore;
  strings: Strings;
}) {
  const loaded = builds.map((b) => s.loaded[b.build]).filter((n): n is ReleaseNotes => !!n);
  const pending = builds.some((b) => !s.loaded[b.build] && !s.unavailable[b.build]);
  const rows = sheetRows(mergedView(loaded, strings.language), strings);
  const installed = builds.some((b) => b.build === s.current);
  return (
    <section
      className="clj-section cls-day"
      ref={loadNear(builds, store, pending)}
      aria-label={dayLabel(day, strings.language)}
    >
      <h2 className="cls-date">
        <time dateTime={day}>{dayLabel(day, strings.language)}</time>
        {installed && <span className="cl-installed">{strings.t("changelog.page.current")}</span>}
      </h2>
      {pending && rows.length === 0 ? (
        <div
          className="clj-placeholder"
          aria-busy="true"
          style={{ "--cls-rows": placeholderRows(builds) } as CSSProperties}
        />
      ) : rows.length === 0 ? (
        <Maintenance strings={strings} />
      ) : (
        <ul className="cls-rows">
          {rows.map((row) => (
            <li className="cls-row" key={row.key}>
              <span className="cls-icon" data-category={row.category} aria-hidden="true">
                <CategoryIcon category={row.category} />
              </span>
              <div className="cls-row-text">
                <div className="cls-row-title">{row.title}</div>
                {row.line && <div className="cls-row-line">{row.line}</div>}
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

/** About how many rows a loading day will have: its highlights as the index counts them, else
    three. The placeholder holds that height, so the days under it barely move when the rows
    arrive (gallery shift baselines nightly-update, nightly-history, many-builds). */
export function placeholderRows(builds: IndexEntry[]): number {
  const highlights = builds.reduce((sum, b) => sum + b.highlights, 0);
  return Math.min(highlights > 0 ? highlights : 3, 60);
}

interface SheetRow {
  key: string;
  category: WhatsNewCategory;
  title: string;
  line?: string;
}

/** A day's rows: its curated changes (hero first, then New, Improved, Fixed, Security), each with its
    summary's first sentence; with none curated, its readable changes, each with its app area. */
export function sheetRows(view: ReleaseView, strings: Strings): SheetRow[] {
  const curated = [...(view.hero ? [view.hero] : []), ...view.groups.flatMap((g) => g.items)];
  if (curated.length > 0)
    return curated.map((item) => ({
      key: item.id,
      category: item.category,
      title: item.title,
      line: firstSentence(item.summary),
    }));
  return view.changes.map((change, index) => ({
    key: `${change.pr ?? ""}:${index}`,
    category: "improved",
    title: change.title,
    line: change.area ? strings.t(`updates.area.${change.area}`) : undefined,
  }));
}

/** "A link opens in the pane. Unread dots wait." reads "A link opens in the pane."; the whole text
    when it has one sentence; undefined when empty. */
function firstSentence(text: string): string | undefined {
  const trimmed = text.trim();
  if (!trimmed) return undefined;
  const end = /[.!?。！？](?=\s|$)/.exec(trimmed);
  return end ? trimmed.slice(0, end.index + 1) : trimmed;
}

/** A 16 pt stroke glyph per kind: a sparkle (new), an arrow up (improved), a check (fixed), a lock
    (security). Drawn in the theme's accent (styles.css .cls-icon). */
function CategoryIcon({ category }: { category: WhatsNewCategory }) {
  return (
    <svg viewBox="0 0 20 20" width="16" height="16">
      {category === "new" && (
        <path d="M10 2.5l1.6 4.3 4.4 1.7-4.4 1.7L10 14.5l-1.6-4.3L4 8.5l4.4-1.7z M15.5 13.5l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7z" />
      )}
      {category === "improved" && (
        <>
          <circle cx="10" cy="10" r="7.25" />
          <path d="M10 13.5v-7M7 9.5l3-3 3 3" />
        </>
      )}
      {category === "fixed" && (
        <>
          <circle cx="10" cy="10" r="7.25" />
          <path d="M6.75 10.25l2.25 2.25 4.25-4.75" />
        </>
      )}
      {category === "security" && (
        <>
          <rect x="4.75" y="8.75" width="10.5" height="8" rx="2" />
          <path d="M7 8.75V6.5a3 3 0 0 1 6 0v2.25" />
        </>
      )}
    </svg>
  );
}
