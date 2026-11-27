// Design A, Journal (cx-urd.61; Lawrence 2026-10-11 picked it, 2026-10-12 "improve this UI").
// Nightlies ship many builds a day, most with no change a person would notice, so the page is
// written around days and the update, not builds:
//  - After an update: "What's new since your last update", every human change of the span's
//    builds once (New / Improved / Fixed / Security, a hero when one has media), then every
//    change by area with its pull request, internal work folded "Under the hood". No nightly
//    reel video: a stitched recording of the span's tours showed no change (Leo, 2026-10-31).
//  - Then one section per release day ("Today", "Yesterday", "Oct 6"), its builds merged; the
//    build numbers are small and selectable, never a headline.
//  - A run of builds with no human change says "Maintenance and fixes", never a blank row.
// J and K move between sections. Notes load as a day nears the viewport (the span at once). A long
// index draws only the days on screen and a few either side (useDayWindow), each day redrawn only
// when its own notes or builds change (sameDay).
// The Ledger (u5099, the default) is this page laid out as conductor.build/changelog: each day's
// newest version as a small tag and its date sit sticky in the left margin, the changes beside them.
import {
  memo,
  useCallback,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type FocusEvent,
  type KeyboardEvent,
  type ReactNode,
  type RefObject,
} from "react";
import {
  defaultRangeExtractor,
  measureElement,
  useWindowVirtualizer,
  type Range,
  type Virtualizer,
} from "@tanstack/react-virtual";
import { KeyboardScope } from "../../ui/KeyboardScope";
import type { Strings } from "../shared/i18n";
import { dayLabel, groupByDay, mergedView, releaseTitle } from "./model";
import { cardVersion } from "./UpdateSurfaces";
import {
  BuildNumbers,
  ChangesFold,
  Groups,
  Hero,
  Maintenance,
  NotesUnavailable,
  type PartsContext,
} from "./ReleaseParts";
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
  const ctx = useMemo<PartsContext>(
    () => ({ strings, onTry: (id) => void store.tryIt(id), rowMedia: ledger, news }),
    [strings, store, ledger, news],
  );
  const { fresh, earlier } = useMemo(() => {
    const span = new Set(s.inSpan);
    return {
      fresh: s.builds.filter((b) => span.has(b.build)),
      earlier: s.span ? s.builds.filter((b) => !span.has(b.build)) : s.builds,
    };
  }, [s.builds, s.inSpan, s.span]);
  const days = useMemo(() => groupByDay(earlier), [earlier]);
  const list = useRef<HTMLDivElement>(null);
  const shown = useDayWindow(list, days, DAY_HEIGHT);
  return (
    <KeyboardScope className="clw" handleKeyDown={journalKeys}>
      <main aria-label={strings.t("changelog.page.title")}>
        {s.span && <SpanSection s={s} fresh={fresh} ctx={ctx} failed={s.failed} store={store} />}
        <div className={ledger ? "clj cll" : "clj"}>
          {!s.span && s.failed && <p className="cl-error">{s.failed}</p>}
          {!s.span && <h1 className="clj-title">{strings.t("changelog.page.title")}</h1>}
          {!s.span && s.builds.length === 0 && <p className="cl-muted">{strings.t("changelog.page.noHistory")}</p>}
          {s.span && earlier.length > 0 && <div className="clj-marker">{strings.t("changelog.page.earlier")}</div>}
          <div className="clj-days" ref={list} onFocus={shown.onFocus}>
            {shown.days.map(({ index, gap }) => {
              const day = days[index]!;
              return (
                <DayRoom key={dayKey(day)} gap={gap}>
                  <DaySection
                    index={index}
                    measure={shown.measure}
                    day={day.day}
                    builds={day.builds}
                    s={s}
                    store={store}
                    ctx={ctx}
                    ledger={ledger}
                  />
                </DayRoom>
              );
            })}
            {shown.after > 0 && <div aria-hidden="true" style={{ height: shown.after }} />}
          </div>
        </div>
      </main>
    </KeyboardScope>
  );
}

/** About how tall a journal day is before it is drawn: its placeholder, date and build numbers. */
const DAY_HEIGHT = 220;

/** The update's own section: what changed from the version before it to this one. It spans the
    tab's width up to a cap (Leo 2026-10-21: "how are you still going this narrow"), above the
    narrower history. */
function SpanSection({
  s,
  fresh,
  ctx,
  failed,
  store,
}: {
  s: ChangelogSnapshot;
  fresh: IndexEntry[];
  ctx: PartsContext;
  failed?: string;
  store: ChangelogStore;
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
      <SectionBody
        view={view}
        pending={pending}
        ctx={ctx}
        // The span's builds are not in the list yet: Try again reads the list again (store.ts `retry`).
        onRetryUnpublished={fresh.length === 0 ? () => void store.retry() : undefined}
        news
      />
    </section>
  );
}

const DaySection = memo(function DaySection({
  index,
  measure,
  day,
  builds,
  s,
  store,
  ctx,
  ledger = false,
}: {
  /** Its place in the day list, which useDayWindow's `measure` reads. */
  index: number;
  measure: (el: Element | null) => void;
  day: string;
  builds: IndexEntry[];
  s: ChangelogSnapshot;
  store: ChangelogStore;
  ctx: PartsContext;
  ledger?: boolean;
}) {
  const loaded = builds.map((b) => s.loaded[b.build]).filter((n): n is ReleaseNotes => !!n);
  const pending = builds.some((b) => !s.loaded[b.build] && !s.unavailable[b.build]);
  const near = dayRef(measure, loadNear(builds, store, pending));
  const view = mergedView(loaded, ctx.strings.language);
  const installed = builds.some((b) => b.build === s.current);
  const title = ledger ? releaseTitle(loaded, ctx.strings.language) : undefined;
  // The release title already names the lead change when it starts with it ("X, and 3 more").
  const heroTitled = !title || !view.hero || !title.startsWith(view.hero.title);
  if (ledger)
    return (
      <section
        className="clj-section cll-release"
        ref={near}
        data-index={index}
        aria-label={dayLabel(day, ctx.strings.language)}
      >
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
    <section className="clj-section" ref={near} data-index={index} aria-label={dayLabel(day, ctx.strings.language)}>
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
}, sameDay);

/** Whether a day draws the same: the same props, and in the snapshot the same notes and the same
    running build for its own builds. A note that loads for one day leaves every other day as it was. */
export function sameDay<P extends { s: ChangelogSnapshot; builds: IndexEntry[] }>(a: P, b: P): boolean {
  for (const key in a) if (key !== "s" && !Object.is(a[key], b[key])) return false;
  if (a.s === b.s) return true;
  if (a.s.current !== b.s.current) return false;
  return a.builds.every(
    ({ build }) => a.s.loaded[build] === b.s.loaded[build] && a.s.unavailable[build] === b.s.unavailable[build],
  );
}

/** A day's key in the list: its date and newest build. */
export function dayKey(day: { day: string; builds: IndexEntry[] }): string {
  return day.day + day.builds[0]!.build;
}

/** A drawn day, after the room the days above it that are not drawn would take. */
export function DayRoom({ gap, children }: { gap: number; children: ReactNode }) {
  return (
    <>
      {gap > 0 && <div aria-hidden="true" style={{ height: gap }} />}
      {children}
    </>
  );
}

/** A day section's ref: `measure` sizes it for the day list (and lets it go when it unmounts),
    `near` loads its notes. */
export function dayRef(measure: (el: Element | null) => void, near: ReturnType<typeof loadNear>) {
  return (el: HTMLElement | null) => {
    measure(el);
    const stop = near(el);
    return () => {
      if (typeof stop === "function") stop();
      measure(null);
    };
  };
}

/** A day list longer than this draws only the days in or near the viewport; a shorter one draws
    every day, as the page always did. */
export const WINDOW_DAYS = 40;

/** How many days past each edge of the viewport a long list keeps drawn. A day is about a screen
    tall or more, so this is a screen or more either side: J and K always find the next day drawn. */
const DAY_OVERSCAN = 2;

const NO_DAYS: readonly number[] = [];

/** What a day list draws: `days`, the indexes of the days in or near the viewport in order (every
    day, under WINDOW_DAYS), each with the room the days not drawn above it take (`gap`); `after`,
    the room under the last; `measure`, each drawn day's ref (with `data-index`), which sizes it;
    `onFocus`, the list's, which keeps the day holding the focus drawn. */
export interface DayWindow {
  days: { index: number; gap: number }[];
  after: number;
  measure: (el: Element | null) => void;
  onFocus: (event: FocusEvent<HTMLElement>) => void;
}

/** Windows a page's day list over the document's scroll (TanStack's window virtualizer): a long
    nightly index mounts the days on screen and DAY_OVERSCAN either side, and holds the rest as
    room, so the page is as tall, scrolls and keeps its place as with every day mounted. `list` wraps
    the days; `height` guesses a day's height before it is drawn; `pinned` days stay drawn wherever
    the page is scrolled (the days a focus may scroll to), and so does the day holding the keyboard
    focus, so scrolling it away keeps the focus, and J and K, in the page. */
export function useDayWindow(
  list: RefObject<HTMLElement | null>,
  days: { day: string; builds: IndexEntry[] }[],
  height: number | ((day: { day: string; builds: IndexEntry[] }) => number),
  pinned: readonly number[] = NO_DAYS,
): DayWindow {
  const windowed = days.length > WINDOW_DAYS;
  // Where the list starts on the page: what is above it (the update's section) grows as it loads.
  const [top, setTop] = useState(0);
  useLayoutEffect(() => {
    const element = list.current;
    if (!windowed || !element) return undefined;
    const place = () =>
      setTop(Math.round(element.getBoundingClientRect().top + (element.ownerDocument.defaultView?.scrollY ?? 0)));
    place();
    const resize = typeof ResizeObserver === "function" ? new ResizeObserver(place) : undefined;
    resize?.observe(element.closest("main") ?? element);
    return () => resize?.disconnect();
  }, [list, windowed]);
  const [focused, setFocused] = useState<number>();
  const onFocus = (event: FocusEvent<HTMLElement>) => {
    const index = Number((event.target as Element).closest("[data-index]")?.getAttribute("data-index"));
    setFocused(Number.isInteger(index) ? index : undefined);
  };
  // Each day's key, read once per list: TanStack asks for every day's key after a day changes size.
  const keys = useMemo(() => days.map(dayKey), [days]);
  // A day not drawn yet is guessed as tall as the first day measured, so drawing one as the page
  // scrolls does not move every day under it (TanStack places each again when a size differs from
  // its guess); `height` guesses until then.
  const first = useMemo<{ size?: number }>(() => ({}), []);
  const sizes = useMemo(
    () => ({
      estimateSize: (index: number) => first.size ?? (typeof height === "number" ? height : height(days[index]!)),
      getItemKey: (index: number) => keys[index]!,
      measureElement: (
        element: Element,
        entry: ResizeObserverEntry | undefined,
        instance: Virtualizer<Window, Element>,
      ) => {
        const size = withMarginBelow(element, entry, instance);
        if (first.size === undefined && size > 0) first.size = size;
        return size;
      },
    }),
    [days, keys, height, first],
  );
  const rangeExtractor = useCallback(
    (range: Range) => {
      const near = defaultRangeExtractor(range);
      const held = focused === undefined ? pinned : [...pinned, focused];
      const far = held.filter((index) => index < range.count && !near.includes(index));
      return far.length === 0 ? near : [...new Set([...far, ...near])].sort((a, b) => a - b);
    },
    [pinned, focused],
  );
  const virtualizer = useWindowVirtualizer({
    count: days.length,
    enabled: windowed,
    overscan: DAY_OVERSCAN,
    scrollMargin: top,
    rangeExtractor,
    ...sizes,
  });
  if (!windowed) return { days: days.map((_, index) => ({ index, gap: 0 })), after: 0, measure: noMeasure, onFocus };
  let end = top;
  const shown = virtualizer.getVirtualItems().map((item) => {
    const gap = item.start - end;
    end = item.end;
    return { index: item.index, gap };
  });
  const after = Math.max(0, virtualizer.getTotalSize() + top - end);
  return { days: shown, after, measure: virtualizer.measureElement, onFocus };
}

const noMeasure = () => {};

/** A day's height with the margin under it (styles.css .clj-section), which its box leaves out. */
function withMarginBelow(
  element: Element,
  entry: ResizeObserverEntry | undefined,
  instance: Virtualizer<Window, Element>,
) {
  const margin = element.ownerDocument.defaultView?.getComputedStyle(element).marginBottom;
  return measureElement(element, entry, instance) + (Number.parseFloat(margin ?? "") || 0);
}

/** A day section's ref: it loads the notes of `builds` once the section nears the viewport (at once
    when it already is: the first frame waits for it, paintGate.ts). Nothing while none is pending. */
export function loadNear(builds: IndexEntry[], store: ChangelogStore, pending: boolean) {
  return (el: HTMLElement | null) => {
    if (!el || !pending) return;
    const load = () => builds.forEach((b) => void store.ensure(b.build));
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
  onRetryUnpublished,
  heroTitled = true,
  news = false,
}: {
  view: ReturnType<typeof mergedView>;
  pending: boolean;
  ctx: PartsContext;
  /** Set when the section's builds are not published in the list yet: its line and Try again. */
  onRetryUnpublished?: () => void;
  heroTitled?: boolean;
  /** The update's own section reads as happy news (SpanNews.tsx); a day keeps its hero and lists. */
  news?: boolean;
}) {
  const unpublished = onRetryUnpublished !== undefined;
  // The update waits for every build of its span (they load at once): drawn early, its fold would
  // open on the first build's bare changes and close again when a later build's notes arrive.
  if (pending && (news || (view.count === 0 && view.changes.length === 0)))
    return <div className="clj-placeholder" aria-busy="true" />;
  return (
    <>
      {!news && view.hero && <Hero item={view.hero} ctx={ctx} titled={heroTitled} />}
      {view.count === 0 && view.changes.length === 0 && !unpublished && <Maintenance strings={ctx.strings} />}
      {onRetryUnpublished && <NotesUnavailable strings={ctx.strings} onRetry={onRetryUnpublished} />}
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
export function journalKeys(event: KeyboardEvent<HTMLDivElement>) {
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
