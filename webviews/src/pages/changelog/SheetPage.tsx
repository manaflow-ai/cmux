// The What's New sheet, the page's default design (Lawrence 2026-10-31, msg 19251: "what's new page
// looks bad, make many variations for me to pick from"; the default of cmux-shots/whatsnew-variations).
// Laid out as the What's New sheet of an Apple app: "What's New", then the release days newest first,
// each under its date. A day's changes sit under the app area each is in (Sidebar, Agent chat,
// Terminal, Cloud, …, then Other), each area a glyph, its name and its count, the most changed area
// first, the area list of #22838 (Leo 2026-11-02: "why is the what's new the 0 information density
// one", on a day that listed every change as one long run of the same arrow). Each change is one
// tight line: its title, then what its description adds; a long area shows its first rows and
// "Show more". No internal codes, filler or infrastructure (model.ts readableItem, readableChange.ts WORK_CODES,
// readableChange). No version tags, build numbers or pull request chips: the Ledger
// (`design=ledger`) keeps them. A day with nothing a person would notice says "Maintenance and
// fixes". Days load as they near the viewport (JournalPage.loadNear); J and K move between them.
// `layout` (the route's `sheet=`) sets the rows; styles.css .cls-inline. A row's kind (model.ts
// rowKind reads a machine line's wording) marks it in the gutter under the area glyph: a plus for
// New, a check for Fixed, a shield for Security, nothing for Improved, so a day is not one run of
// the same mark (Leo 2026-11-02). Model.ts readableItem joins a line that is the rest of its title
// back into the title, and a line that repeats it becomes the title.
// Each day's header has "Versions" (Leo 2026-11-05: "Like literally with a click to a past nightly
// ... through the What's New page, you can just get back to a prior version if you wanted to"): its
// builds, each with its commit, its changes since the build before, and Install, which asks once,
// then has the app download that build, check its signature and team, and restart into it.
import { useState, type CSSProperties, type ReactNode } from "react";
import { KeyboardScope } from "../../ui/KeyboardScope";
import { Button } from "../../ui/Button";
import type { Strings } from "../shared/i18n";
import { areaOf, byArea, type AreaKey } from "./areas";
import { dayLabel, groupByDay, isFiller, mergedView, rowKind, type ReleaseView } from "./model";
import { withoutWorkCodes } from "./readableChange";
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
  const [versions, setVersions] = useState(false);
  return (
    <section
      className="clj-section cls-day"
      ref={loadNear(builds, store, pending)}
      aria-label={dayLabel(day, strings.language)}
    >
      <h2 className="cls-date">
        <time dateTime={day}>{dayLabel(day, strings.language)}</time>
        {installed && <span className="cl-installed">{strings.t("changelog.page.current")}</span>}
        <Button
          size="sm"
          variant="ghost"
          className="cls-versions-toggle"
          aria-expanded={versions}
          onClick={() => setVersions(!versions)}
        >
          {strings.t("changelog.build.versions")}
          <span className="cl-count">{builds.length}</span>
        </Button>
      </h2>
      {versions && <SheetBuilds builds={builds} all={s.builds} s={s} store={store} strings={strings} />}
      {pending && rows.length === 0 ? (
        <div
          className="clj-placeholder"
          aria-busy="true"
          style={
            {
              "--cls-rows": placeholderRows(builds),
              "--cls-areas": placeholderAreas(builds),
            } as CSSProperties
          }
        />
      ) : rows.length === 0 ? (
        <Maintenance strings={strings} />
      ) : (
        byArea(rows).map((group) => (
          <SheetArea key={group.area ?? ""} area={group.area} rows={group.items} strings={strings} />
        ))
      )}
    </section>
  );
}

const COMMITS = "https://github.com/manaflow-ai/cmux";

/** A day's builds, newest first: version, commit, changes since the build before it (the next
    older listed one), and Install (Installed for the running build). Install asks once ("Restart
    into it"); a refusal stays under its build. */
export function SheetBuilds({
  builds,
  all,
  s,
  store,
  strings,
}: {
  builds: IndexEntry[];
  all: IndexEntry[];
  s: ChangelogSnapshot;
  store: ChangelogStore;
  strings: Strings;
}) {
  const [asking, setAsking] = useState<string>();
  return (
    <ul className="cls-builds">
      {builds.map((b) => {
        const before = all[all.findIndex((x) => x.build === b.build) + 1];
        const failed = s.installFailed?.build === b.build ? s.installFailed.message : undefined;
        return (
          <li className="cls-build" key={b.build} data-build={b.build}>
            <span className="cls-build-version">{b.shortVersion}</span>
            {b.head && (
              <a className="cls-build-link" href={`${COMMITS}/commit/${b.head}`} rel="noreferrer">
                {b.head.slice(0, 7)}
              </a>
            )}
            {b.head && before?.head && (
              <a className="cls-build-link" href={`${COMMITS}/compare/${before.head}...${b.head}`} rel="noreferrer">
                {strings.t("changelog.build.changes")}
              </a>
            )}
            <span className="cls-build-action">
              {b.build === s.current ? (
                <span className="cl-installed">{strings.t("changelog.page.current")}</span>
              ) : !s.installs ? null : s.installing === b.build ? (
                <Button size="sm" variant="ghost" disabled aria-busy="true">
                  {strings.t("changelog.build.installing")}
                </Button>
              ) : asking === b.build ? (
                <Button size="sm" disabled={!!s.installing} onClick={() => void store.install(b.build)}>
                  {strings.t("changelog.build.confirm")}
                </Button>
              ) : (
                <Button size="sm" variant="ghost" disabled={!!s.installing} onClick={() => setAsking(b.build)}>
                  {strings.t("changelog.build.install")}
                </Button>
              )}
            </span>
            {failed && <span className="cls-build-failed">{failed}</span>}
          </li>
        );
      })}
    </ul>
  );
}

/** An area shows this many changes, then "Show more" (and how many it hides) for the rest. */
export const AREA_ROWS = 6;

function SheetArea({ area, rows, strings }: { area?: AreaKey; rows: SheetRow[]; strings: Strings }) {
  const [open, setOpen] = useState(false);
  const label = area ? strings.t(`updates.area.${area}`) : strings.t("changelog.page.otherArea");
  // A fold that would hide one row hides none: the button would take that row's line.
  const shown = open || rows.length <= AREA_ROWS + 1 ? rows : rows.slice(0, AREA_ROWS);
  return (
    <section className="cls-area" aria-label={label} data-area={area ?? "other"}>
      <h3 className="cls-area-head">
        <span className="cls-icon" aria-hidden="true">
          <AreaIcon area={area} />
        </span>
        <span className="cls-area-name">{label}</span>
        <span className="cl-count">{rows.length}</span>
      </h3>
      <ul className="cls-rows">
        {shown.map((row) => (
          <li className="cls-row" key={row.key} data-category={row.category}>
            {KIND_GLYPHS[row.category] && (
              <span className="cls-icon cls-kind" aria-hidden="true">
                <svg viewBox="0 0 20 20" width="14" height="14">
                  {KIND_GLYPHS[row.category]}
                </svg>
              </span>
            )}
            <span className="cls-row-title">{row.title}</span>
            {row.line && <span className="cls-row-line">{row.line}</span>}
          </li>
        ))}
      </ul>
      {shown.length < rows.length && (
        <Button size="sm" variant="ghost" className="cl-more cls-more" onClick={() => setOpen(true)}>
          {strings.t("changelog.page.showMore")}
          <span className="cl-count">{rows.length - shown.length}</span>
        </Button>
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

/** About how many area headers a loading day will draw. With a highlight count, a day's changes
    spread over more areas as it grows, but slower than its rows (real nightly days: 1 change in 1
    area, 3 in 3, 10 in 6, 26 in 9; at most 13, at the 60-row cap); with none, one (a day the
    index counts nothing for has one to four changes in one to four areas, the three-row guess plus
    one header is their mean). The placeholder reserves each header's line and gap (styles.css
    .cls-area), since #32744 grouped a day by area: without them a loaded day came out taller than
    its placeholder and pushed the days under it down (gallery shift rows pages.changelog#sheet,
    #current, #nightly-unpublished). */
export function placeholderAreas(builds: IndexEntry[]): number {
  const highlights = builds.reduce((sum, b) => sum + b.highlights, 0);
  if (highlights <= 0) return 1;
  const rows = placeholderRows(builds);
  return Math.min(rows, Math.ceil(1.6 * Math.sqrt(rows)));
}

export interface SheetRow {
  key: string;
  category: WhatsNewCategory;
  title: string;
  line?: string;
  /** The app area the change is in (areas.ts), none for Other. */
  area?: AreaKey;
}

/** A day's rows: its curated changes (hero first, then New, Improved, Fixed, Security), each with
    what its summary's first sentence adds to the title; with none curated, its readable changes,
    each with its description. Each knows its app area. */
export function sheetRows(view: ReleaseView, _strings?: Strings): SheetRow[] {
  const curated = [...(view.hero ? [view.hero] : []), ...view.groups.flatMap((g) => g.items)];
  if (curated.length > 0)
    return curated.map((item) => {
      const line = addedLine(item.title, firstSentence(item.summary));
      return {
        key: item.id,
        category: item.category,
        title: item.title,
        line,
        area: areaOf(item.title) ?? (line ? areaOf(line) : undefined),
      };
    });
  return view.changes.map((change, index) => ({
    key: `${change.pr ?? ""}:${index}`,
    category: rowKind(change.title),
    title: change.title,
    line: addedLine(change.title, fallbackLine(change.description)),
    area: change.area,
  }));
}

/** Words as two lines compare: lower case, no leading article, no punctuation. */
function words(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]/gu, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/^(?:the|a|an) /, "");
}

/** What `line` says beyond `title`: undefined when it only repeats it ("Host pressure warning is
    off by default." under "The host pressure warning is off by default"), its tail when it repeats
    it and goes on ("…; turn it on from the Command Palette." reads "Turn it on from the Command
    Palette."), else the line. */
export function addedLine(title: string, line: string | undefined): string | undefined {
  if (!line) return undefined;
  const head = words(title);
  const body = words(line);
  if (!body || head.includes(body)) return undefined;
  if (!body.startsWith(head)) return line;
  for (const match of line.matchAll(/[;:,—]\s*|\s[-–]\s/g)) {
    if (words(line.slice(0, match.index)) !== head) continue;
    const rest = line.slice(match.index + match[0].length).trim();
    return rest ? rest.charAt(0).toUpperCase() + rest.slice(1) : undefined;
  }
  // It goes on with no clause mark ("Tabs restore after restarting the app." under "The tabs
  // restore"): the whole line says more than the title.
  return line;
}

/** A raw change's description as its row's line: no work-stream codes, no filler ("This build brings
    fixes and improvements."), its first sentence. */
function fallbackLine(description: string | undefined): string | undefined {
  const plain = description ? withoutWorkCodes(description) : "";
  return plain && !isFiller(plain) ? firstSentence(plain) : undefined;
}

/** "A link opens in the pane. Unread dots wait." reads "A link opens in the pane."; the whole text
    when it has one sentence; undefined when empty. */
function firstSentence(text: string): string | undefined {
  const trimmed = text.trim();
  if (!trimmed) return undefined;
  const end = /[.!?。！？](?=\s|$)/.exec(trimmed);
  return end ? trimmed.slice(0, end.index + 1) : trimmed;
}

/** A 16 pt stroke glyph per app area, in the theme's accent (styles.css .cls-icon): the sidebar's
    column, a tab with a plus, a pencil, a speech bubble, a house, tabs, a prompt, a globe, a
    search lens, sliders, an update arrow, a keyboard, split panes, a window, a cloud; three dots
    for Other. */
export function AreaIcon({ area }: { area?: AreaKey }) {
  return (
    <svg viewBox="0 0 20 20" width="16" height="16">
      {AREA_GLYPHS[area ?? "other"]}
    </svg>
  );
}

/** A row's kind in the gutter (styles.css .cls-kind); Improved, the most common, shows none. */
const KIND_GLYPHS: Partial<Record<WhatsNewCategory, ReactNode>> = {
  new: <path d="M10 5v10M5 10h10" />,
  fixed: <path d="M5 10.5l3.2 3.1L15 6.8" />,
  security: <path d="M10 3.5l5.5 2v4.2c0 3.3-2.3 5.6-5.5 6.8-3.2-1.2-5.5-3.5-5.5-6.8V5.5z" />,
};

const FRAME = <rect x="3" y="4" width="14" height="12" rx="2" />;
const AREA_GLYPHS: Record<AreaKey | "other", ReactNode> = {
  sidebar: (
    <>
      {FRAME}
      <path d="M8 4v12" />
    </>
  ),
  newTab: (
    <>
      {FRAME}
      <path d="M10 7.5v5M7.5 10h5" />
    </>
  ),
  composer: <path d="M4.5 15.5l.9-3.6 7.6-7.6 2.7 2.7-7.6 7.6zM11.6 5.7l2.7 2.7" />,
  agentChat: (
    <path d="M5.5 4h9A1.5 1.5 0 0 1 16 5.5v6a1.5 1.5 0 0 1-1.5 1.5H9.2L6 15.8V13h-.5A1.5 1.5 0 0 1 4 11.5v-6A1.5 1.5 0 0 1 5.5 4z" />
  ),
  home: <path d="M3.5 9.5L10 4l6.5 5.5M5.5 8v7.5h9V8" />,
  tabs: (
    <>
      <rect x="3" y="7" width="14" height="9" rx="1.5" />
      <path d="M5.5 7V5.5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1V7" />
    </>
  ),
  terminal: (
    <>
      {FRAME}
      <path d="M6.5 8l2 2-2 2M10.5 12.5h3" />
    </>
  ),
  browser: (
    <>
      <circle cx="10" cy="10" r="7" />
      <path d="M3 10h14M10 3c1.9 2 2.8 4.4 2.8 7s-.9 5-2.8 7M10 3C8.1 5 7.2 7.4 7.2 10s.9 5 2.8 7" />
    </>
  ),
  palette: (
    <>
      <circle cx="9" cy="9" r="5" />
      <path d="M12.7 12.7l3.8 3.8" />
    </>
  ),
  settings: (
    <>
      <path d="M4 6.5h12M4 13.5h12" />
      <circle cx="8" cy="6.5" r="1.8" />
      <circle cx="12" cy="13.5" r="1.8" />
    </>
  ),
  updates: <path d="M16 10a6 6 0 1 1-1.8-4.3M16 3.8v3.4h-3.4" />,
  keyboard: (
    <>
      <rect x="2.5" y="5.5" width="15" height="9" rx="1.5" />
      <path d="M5.5 8.5h1M9.5 8.5h1M13.5 8.5h1M6.5 11.5h7" />
    </>
  ),
  panes: (
    <>
      {FRAME}
      <path d="M10 4v12M10 10h7" />
    </>
  ),
  windows: (
    <>
      {FRAME}
      <path d="M3 7.5h14" />
    </>
  ),
  cloud: <path d="M6.2 15.5h8.1a3 3 0 0 0 .4-6A4.6 4.6 0 0 0 5.9 8.7a3.4 3.4 0 0 0 .3 6.8z" />,
  other: <path d="M5 10h.01M10 10h.01M15 10h.01" />,
};
