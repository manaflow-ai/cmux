// Design A, Journal (cx-urd.61; Lawrence 2026-10-11 picked it, 2026-10-12 "improve this UI").
// Nightlies ship many builds a day, most with no change a person would notice, so the page is
// written around days and the update, not builds:
//  - After an update: "What's new since your last update", every human change of the span's
//    builds once (New / Improved / Fixed / Security, a hero when one has media), then every
//    change by area with its pull request, internal work folded "Under the hood". The span's
//    nightly reels come first, one card each.
//  - Then one section per release day ("Today", "Yesterday", "Oct 6"), its builds merged; the
//    build numbers are small and selectable, never a headline.
//  - A run of builds with no human change says "Maintenance and fixes", never a blank row.
// J and K move between sections. Notes load as a day nears the viewport (the span at once).
// The Ledger (u5099, the default) is this page laid out as conductor.build/changelog: each day's
// newest version as a small tag and its date sit sticky in the left margin, the changes beside them.
import type { KeyboardEvent } from "react";
import { KeyboardScope } from "../../ui/KeyboardScope";
import type { Strings } from "../shared/i18n";
import { dayLabel, groupByDay, mergedView, releaseTitle } from "./model";
import { cardVersion } from "./UpdateSurfaces";
import { BuildNumbers, ChangesFold, Groups, Hero, Maintenance, ReelPlayer, type PartsContext } from "./ReleaseParts";
import { SpanNews } from "./SpanNews";
import type { ChangelogSnapshot, ChangelogStore } from "./store";
import type { IndexEntry, NewsLayout, ReleaseNotes } from "./types";

export function JournalPage({
  store,
  strings,
  s,
  ledger = false,
  news,
}: {
  store: ChangelogStore;
  strings: Strings;
  s: ChangelogSnapshot;
  ledger?: boolean;
  news?: NewsLayout;
}) {
  const ctx: PartsContext = { strings, onTry: (id) => void store.tryIt(id), rowMedia: ledger, news };
  const span = new Set(s.inSpan);
  const fresh = s.builds.filter((b) => span.has(b.build));
  const earlier = s.span ? s.builds.filter((b) => !span.has(b.build)) : s.builds;
  return (
    <KeyboardScope className="clw" handleKeyDown={journalKeys}>
      <main aria-label={strings.t("changelog.page.title")}>
        {s.span && <SpanSection s={s} fresh={fresh} ctx={ctx} failed={s.failed} />}
        <div className={ledger ? "clj cll" : "clj"}>
          {!s.span && s.failed && <p className="cl-error">{s.failed}</p>}
          {!s.span && <h1 className="clj-title">{strings.t("changelog.page.title")}</h1>}
          {!s.span && s.builds.length === 0 && <p className="cl-muted">{strings.t("changelog.page.noHistory")}</p>}
          {s.span && earlier.length > 0 && <div className="clj-marker">{strings.t("changelog.page.earlier")}</div>}
          {groupByDay(earlier).map((day) => (
            <DaySection
              key={day.day + day.builds[0]!.build}
              day={day.day}
              builds={day.builds}
              s={s}
              store={store}
              ctx={ctx}
              ledger={ledger}
            />
          ))}
        </div>
      </main>
    </KeyboardScope>
  );
}

/** The update's own section: what changed from the version before it to this one. It spans the
    tab's width up to a cap (Leo 2026-10-21: "how are you still going this narrow"), above the
    narrower history. */
function SpanSection({
  s,
  fresh,
  ctx,
  failed,
}: {
  s: ChangelogSnapshot;
  fresh: IndexEntry[];
  ctx: PartsContext;
  failed?: string;
}) {
  const loaded = fresh.map((b) => s.loaded[b.build]).filter((n): n is ReleaseNotes => !!n);
  const pending = fresh.some((b) => !s.loaded[b.build] && !s.unavailable[b.build]);
  const view = mergedView(loaded, ctx.strings.language);
  const span = s.span!;
  return (
    <section className="clj-section clj-span" data-testid="changelog.sinceLastUpdate" aria-labelledby="clj-span-title">
      {failed && <p className="cl-error">{failed}</p>}
      <h1 className="clj-title" id="clj-span-title">
        {ctx.strings.t("changelog.page.sinceTitle")}
      </h1>
      <div className="cl-builds">
        {span.from ? (
          <>
            <span className="cl-build">{span.from}</span>
            <span aria-hidden="true"> → </span>
          </>
        ) : null}
        <span className="cl-build" data-testid="changelog.updatedTo">
          {span.to}
        </span>
      </div>
      <ReelPlayer builds={fresh} reels={s.reels} strings={ctx.strings} />
      <SectionBody view={view} pending={pending} ctx={ctx} unpublished={fresh.length === 0} news />
    </section>
  );
}

function DaySection({
  day,
  builds,
  s,
  store,
  ctx,
  ledger = false,
}: {
  day: string;
  builds: IndexEntry[];
  s: ChangelogSnapshot;
  store: ChangelogStore;
  ctx: PartsContext;
  ledger?: boolean;
}) {
  const loaded = builds.map((b) => s.loaded[b.build]).filter((n): n is ReleaseNotes => !!n);
  const pending = builds.some((b) => !s.loaded[b.build] && !s.unavailable[b.build]);
  const near = (el: HTMLElement | null) => {
    if (!el || !pending) return;
    const load = () => builds.forEach((b) => void store.ensure(b.build));
    // A day already near the viewport loads now: the first frame waits for it (paintGate.ts).
    if (typeof IntersectionObserver === "undefined" || nearViewport(el)) return load();
    const observer = new IntersectionObserver(
      (records) => {
        if (!records.some((r) => r.isIntersecting)) return;
        observer.disconnect();
        load();
      },
      { rootMargin: `${NEAR_MARGIN}px 0px` },
    );
    observer.observe(el);
    return () => observer.disconnect();
  };
  const view = mergedView(loaded, ctx.strings.language);
  const installed = builds.some((b) => b.build === s.current);
  const title = ledger ? releaseTitle(loaded, ctx.strings.language) : undefined;
  // The release title already names the lead change when it starts with it ("X, and 3 more").
  const heroTitled = !title || !view.hero || !title.startsWith(view.hero.title);
  if (ledger)
    return (
      <section className="clj-section cll-release" ref={near} aria-label={dayLabel(day, ctx.strings.language)}>
        <div className="cll-gutter">
          <div className="cll-gutter-in">
            <span className="cll-version">{cardVersion(builds[0]!.shortVersion)}</span>
            <time dateTime={day}>{dayLabel(day, ctx.strings.language)}</time>
            {installed && <span className="cl-installed">{ctx.strings.t("changelog.page.current")}</span>}
          </div>
        </div>
        <div className="cll-body">
          {title && <h2 className="cll-title">{title}</h2>}
          <SectionBody view={view} pending={pending} ctx={ctx} heroTitled={heroTitled} />
          {builds.length > 1 && <BuildNumbers builds={builds} />}
        </div>
      </section>
    );
  return (
    <section className="clj-section" ref={near} aria-label={dayLabel(day, ctx.strings.language)}>
      <div className="clj-day-row">
        <h2 className="clj-day">
          <time dateTime={day}>{dayLabel(day, ctx.strings.language)}</time>
        </h2>
        {installed && <span className="cl-installed">{ctx.strings.t("changelog.page.current")}</span>}
      </div>
      <BuildNumbers builds={builds} />
      <SectionBody view={view} pending={pending} ctx={ctx} />
    </section>
  );
}

/** How far outside the viewport a day starts loading its notes. */
const NEAR_MARGIN = 800;

function nearViewport(el: HTMLElement): boolean {
  const height = el.ownerDocument.defaultView?.innerHeight ?? 0;
  const rect = el.getBoundingClientRect();
  return rect.top < height + NEAR_MARGIN && rect.bottom > -NEAR_MARGIN;
}

function SectionBody({
  view,
  pending,
  ctx,
  unpublished = false,
  heroTitled = true,
  news = false,
}: {
  view: ReturnType<typeof mergedView>;
  pending: boolean;
  ctx: PartsContext;
  unpublished?: boolean;
  heroTitled?: boolean;
  /** The update's own section reads as happy news (SpanNews.tsx); a day keeps its hero and lists. */
  news?: boolean;
}) {
  // The update waits for every build of its span (they load at once): drawn early, its fold would
  // open on the first build's bare changes and close again when a later build's notes arrive.
  if (pending && (news || (view.count === 0 && view.changes.length === 0)))
    return <div className="clj-placeholder" aria-busy="true" />;
  return (
    <>
      {!news && view.hero && <Hero item={view.hero} ctx={ctx} titled={heroTitled} />}
      {view.count === 0 && view.changes.length === 0 && !unpublished && <Maintenance strings={ctx.strings} />}
      {unpublished && <p className="cl-muted">{ctx.strings.t("changelog.page.unavailable")}</p>}
      {news ? <SpanNews view={view} ctx={ctx} /> : <Groups view={view} ctx={ctx} />}
      {/* With no curated notes the changes are the news, so the update opens them. */}
      <ChangesFold
        changes={view.changes}
        hidden={view.underTheHood}
        strings={ctx.strings}
        open={news && view.count === 0}
      />
    </>
  );
}

/** J and K (from any focused control in the page) jump to the next or previous section. The
    document scrolls, so Space, Page Down and the arrows work with nothing focused. */
function journalKeys(event: KeyboardEvent<HTMLDivElement>) {
  if (event.metaKey || event.ctrlKey || event.altKey || event.defaultPrevented) return;
  const key = event.key.toLowerCase();
  if (key !== "j" && key !== "k") return;
  const doc = event.currentTarget.ownerDocument;
  const sections = [...event.currentTarget.querySelectorAll<HTMLElement>(".clj-section")];
  // A section scrolled into view rests at the scroll padding, not at 0.
  const padding = Number.parseFloat(doc.defaultView?.getComputedStyle(doc.documentElement).scrollPaddingTop ?? "") || 0;
  const top = (r: HTMLElement) => r.getBoundingClientRect().top - padding;
  const target = key === "j" ? sections.find((r) => top(r) > 8) : [...sections].reverse().find((r) => top(r) < -8);
  if (!target) return;
  event.preventDefault();
  const reduce = doc.defaultView?.matchMedia("(prefers-reduced-motion: reduce)").matches;
  target.scrollIntoView({ block: "start", behavior: reduce ? "auto" : "smooth" });
  target.querySelector<HTMLElement>("button, a[href], summary")?.focus({ preventScroll: true });
}
