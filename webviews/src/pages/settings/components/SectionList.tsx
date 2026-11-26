import {
  useCallback,
  useEffect,
  useId,
  useRef,
  useState,
  useSyncExternalStore,
  type ComponentProps,
  type ReactNode,
} from "react";
import { createLink, type AnyRouter } from "@tanstack/react-router";
import { useSettingsState } from "../context";
import { categoryRows, shownSidebarSections, type Category, type SidebarSection } from "../categories";
import { settingsFileName } from "../format";
import { Icon } from "../icons";
import type { SettingsState } from "../store";
import { managedOf } from "../store";
import { t, text } from "../strings";
import { harnessesNeedAttention } from "../harnesses";
import { isExperimentalCategory, useBetaChips } from "../betaChips";
import { BetaChip } from "./BetaChip";
import { followScrollEdges } from "../../../ui/scrollEdges";
import { followStripWheel, revealInStrip } from "./sectionStrip";

function badge(state: SettingsState, category: string): "warning" | "lock" | "update" | null {
  const keys = categoryRows(category).map((row) => row.key);
  if (keys.some((key) => state.diagnostics.has(key))) return "warning";
  if (keys.some((key) => managedOf(state, key) !== null)) return "lock";
  if (category === "agents" && harnessesNeedAttention(state.harnesses)) return "update";
  return null;
}

/** In the app the host draws SF Symbols (`symbol-bold/<name>`, MenuSymbolImages); the gallery and tests
 * have no such route and keep the page's own drawings. */
const hostSymbols = () => globalThis.location?.protocol === "cmux-page:";

/** The host's bold drawing of a symbol (`symbol-bold/<name>`, MenuSymbolImages; Lucas 2026-11-11). */
const symbolHref = (name: string) => `symbol-bold/${encodeURIComponent(encodeURIComponent(name))}`;

/** Symbols whose page drawing reads better than the SF Symbol (Lucas 2026-11-11: he picked these
 * four from feat-cmux-next's sidebar); every other category keeps the host's bold symbol. */
const PAGE_DRAWN: ReadonlySet<string> = new Set(["terminal", "bell", "keyboard", "contextualmenu.and.cursorarrow"]);

/** The host-drawn icons loaded so far, kept so the browser keeps them decoded for the rows' masks. */
const loadedSymbols: HTMLImageElement[] = [];
/** True once ``preloadCategorySymbols`` loaded the icons: only then do the rows mask with them. */
let symbolsLoaded = false;
const symbolListeners = new Set<() => void>();
const watchSymbols = (listener: () => void) => {
  symbolListeners.add(listener);
  return () => symbolListeners.delete(listener);
};

/**
 * Loads and decodes the host's drawing of each symbol the sidebar masks, so the page's first frame has
 * every icon (Lawrence 2026-11-15: "sometimes logos in settings doesnt load fast"). A mask's image is
 * fetched only when its row first paints: the sidebar showed with empty icon slots, then each icon popped
 * in. Worse, a parked spare drew its sidebar before its claim, when the host had no drawing to give: those
 * requests failed, WebKit kept the failures, and most rows of a page claimed from the pool never got an
 * icon. So the rows mask only with what this loaded, after the claim (mount.tsx), and the page's paint
 * report waits for it; a symbol the host cannot draw settles too.
 */
export function preloadCategorySymbols(symbols: Iterable<string>): Promise<void> {
  if (!hostSymbols()) return Promise.resolve();
  const names = [...new Set(symbols)].filter((symbol) => !PAGE_DRAWN.has(symbol));
  return Promise.all(
    names.map((symbol) => {
      const image = new Image();
      loadedSymbols.push(image);
      image.src = symbolHref(symbol);
      return image.decode().catch(() => undefined);
    }),
  ).then(() => {
    symbolsLoaded = true;
    for (const listener of symbolListeners) listener();
  });
}

/** A category's icon: the real SF Symbol it names, the one the window sidebar and menus draw, bold,
 * as a template PNG masking a `currentColor` box, so it inks like the row's text (Lucas 2026-11-11:
 * the page's hand-drawn icons looked cheap beside Aside's and Codex's). */
function CategoryIcon({ symbol }: { symbol: string }) {
  const loaded = useSyncExternalStore(watchSymbols, () => symbolsLoaded);
  if (!hostSymbols() || PAGE_DRAWN.has(symbol)) return <Icon name={symbol} />;
  // Its slot keeps its size until the icon is loaded (no layout shift), empty rather than a filled box.
  const style = loaded ? { maskImage: `url("${symbolHref(symbol)}")` } : { visibility: "hidden" as const };
  return <span className="section-symbol" data-symbol={symbol} style={style} />;
}

const BADGE_TEXT = {
  lock: "settingsPage.managed",
  update: "settingsWindow.harnesses.attention",
} as const;

// The shown category marks its row (`current`), never the router's own active match.
const SectionLink = createLink(function SectionAnchor({
  currentPage,
  children,
  ...props
}: ComponentProps<"a"> & { currentPage: boolean }) {
  return (
    <a {...props} aria-current={currentPage ? "page" : undefined}>
      <span className="section-link-content">{children}</span>
    </a>
  );
});

/** The category list: icon, name, and a badge for problems (warning), managed keys (lock) or an
 * agent CLI that is outdated or signed out (update). Each entry is a router link: hover or keyboard
 * focus preloads its section (the router's `defaultPreload: "intent"`), a click navigates.
 * `current` marks the shown category (null while searching); the link's own active match is exact,
 * so it never marks a section the page is not showing. The top level is six pages (one settings area,
 * David Beyer 2026-11-20: Settings felt overwhelming), each opening its categories while shown. */
export function SectionList({ current, onSelect }: { current: string | null; onSelect: (section: string) => void }) {
  const state = useSettingsState();
  const betaChips = useBetaChips();
  // A narrow pane's strip (sectionStrip.ts): its edges fade where categories are past them, a wheel
  // scrolls it sideways, and the shown category scrolls into view.
  const strip = useRef<HTMLElement | null>(null);
  const stopStrip = useRef<(() => void) | undefined>(undefined);
  const stripRef = useCallback((node: HTMLElement | null) => {
    stopStrip.current?.();
    stopStrip.current = undefined;
    strip.current = node;
    if (!node) return;
    const stopWheel = followStripWheel(node);
    const stopEdges =
      typeof ResizeObserver === "function" && typeof MutationObserver === "function"
        ? followScrollEdges(node, "x")
        : undefined;
    stopStrip.current = () => {
      stopWheel();
      stopEdges?.();
    };
  }, []);
  useEffect(() => {
    const node = strip.current;
    const link = node?.querySelector<HTMLElement>(".section-link[aria-current]");
    if (node && link) revealInStrip(node, link);
  }, [current]);
  const link = (category: Category, page?: { section: SidebarSection; open: boolean }) => {
    const mark = badge(state, category.id);
    // A page's link is its first category's link under the page's title; `data-open` marks the
    // shown page while another of its categories is shown.
    const pageLink = page !== undefined;
    return (
      <SectionLink<AnyRouter, string, string>
        key={category.id}
        to="/settings/$section"
        params={{ section: category.id }}
        activeOptions={{ exact: true }}
        activeProps={{}}
        className={pageLink ? "section-link sidebar-page-link" : "section-link"}
        draggable={false}
        data-section-link={category.id}
        data-sidebar-page={pageLink ? page.section.id : undefined}
        data-open={pageLink && page.open ? "" : undefined}
        currentPage={category.id === current}
        onClick={() => onSelect(category.id)}
      >
        <span className="section-icon" data-category={category.id}>
          <CategoryIcon symbol={category.symbol} />
        </span>
        <span className="section-name">
          {pageLink && page.section.title ? text(page.section.title) : text(category.title)}
        </span>
        {betaChips && isExperimentalCategory(category.id) && <BetaChip />}
        {mark && (
          <span className={`badge badge-${mark}`} data-badge={mark}>
            <Icon name={mark} />
            <span className="visually-hidden">
              {mark === "warning" ? t("settingsPage.problems", settingsFileName(state.host)) : t(BADGE_TEXT[mark])}
            </span>
          </span>
        )}
      </SectionLink>
    );
  };
  // Six pages (one settings area, findings G6; Leo 2026-11-22: "ay, fuck it we ball"): each section of
  // the Swift `SettingsPageLayout.sidebarSections` export is one page link, its first category under
  // the page's title; the shown page's other categories open under it, indented, the way a card's
  // More Options does. A page of one category is just its link. A section the layout draws closed
  // (collapsed) keeps its header button, and an untitled run its bare links.
  return (
    <nav ref={stripRef} className="section-list" aria-label={t("settingsPage.sections")}>
      {shownSidebarSections(state.host?.dev_build === true).map(({ section, categories }) => {
        const holdsCurrent = categories.some((category) => category.id === current);
        if (section.collapsed) {
          return (
            <CollapsedSection key={section.id} section={section} holdsCurrent={holdsCurrent}>
              {categories.map((category) => link(category))}
            </CollapsedSection>
          );
        }
        if (section.title && categories.length > 1) {
          return (
            <SidebarPage
              key={section.id}
              section={section}
              holdsCurrent={holdsCurrent}
              pageLink={link(categories[0]!, { section, open: holdsCurrent })}
            >
              {categories.slice(1).map((category) => link(category))}
            </SidebarPage>
          );
        }
        // A page of one category (Keyboard), or an untitled run: just its links.
        return (
          <div
            key={section.id}
            className={section.title ? "sidebar-section sidebar-page" : "sidebar-section"}
            data-sidebar-section={section.id}
          >
            {categories.map((category) => (section.title ? link(category, { section, open: false }) : link(category)))}
          </div>
        );
      })}
    </nav>
  );
}

/**
 * One of the six pages: its link (its first category, under the section's title), then its other
 * categories, indented, open while one of the page's categories is shown. Closed, they are inert: no
 * Tab stop; a click on the page link opens its first category, which opens them.
 */
function SidebarPage({
  section,
  holdsCurrent,
  pageLink,
  children,
}: {
  section: SidebarSection;
  holdsCurrent: boolean;
  pageLink: ReactNode;
  children: ReactNode;
}) {
  const id = useId();
  return (
    <div
      className="sidebar-section sidebar-page"
      data-sidebar-section={section.id}
      data-open={holdsCurrent ? "" : undefined}
    >
      {pageLink}
      <div
        className="sidebar-more-links sidebar-page-children"
        id={`${id}-links`}
        data-open={holdsCurrent ? "" : undefined}
        inert={!holdsCurrent}
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a labelled group of sidebar links; a fieldset would bring its own box and form semantics
        role="group"
        aria-label={section.title ? text(section.title) : undefined}
      >
        <div className="sidebar-more-rows">{children}</div>
      </div>
    </div>
  );
}

/**
 * A section drawn closed (More): its header is a button with the count of its categories and a
 * chevron, and its links open below it in place, the way a card's More Options does. It opens on a
 * click, and whenever one of its categories is shown (a link, search, the host), so the shown page's
 * row is never hidden; a person can still close it. Closed, its links are inert: no Tab stop.
 */
function CollapsedSection({
  section,
  holdsCurrent,
  children,
}: {
  section: SidebarSection;
  holdsCurrent: boolean;
  children: ReactNode;
}) {
  const id = useId();
  const [open, setOpen] = useState(holdsCurrent);
  const [held, setHeld] = useState(holdsCurrent);
  if (held !== holdsCurrent) {
    setHeld(holdsCurrent);
    if (holdsCurrent && !open) setOpen(true);
  }
  // The shown categories (a DEV-only one is gone outside DEV builds).
  const count = Array.isArray(children) ? children.length : 1;
  return (
    <div
      className="sidebar-section sidebar-section-collapsible"
      data-sidebar-section={section.id}
      data-open={open ? "" : undefined}
    >
      <button
        type="button"
        className="sidebar-more"
        aria-expanded={open}
        aria-controls={`${id}-links`}
        id={`${id}-header`}
        onClick={() => setOpen(!open)}
      >
        <span className="sidebar-more-label">{text(section.title)}</span>
        <span className="sidebar-more-count" aria-hidden="true">
          {count}
        </span>
        <Icon name="chevron" className="sidebar-more-chevron" />
      </button>
      <div
        className="sidebar-more-links"
        id={`${id}-links`}
        data-open={open ? "" : undefined}
        inert={!open}
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a labelled group of sidebar links; a fieldset would bring its own box and form semantics
        role="group"
        aria-labelledby={`${id}-header`}
      >
        <div className="sidebar-more-rows">{children}</div>
      </div>
    </div>
  );
}
