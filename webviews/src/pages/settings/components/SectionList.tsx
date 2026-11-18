import { useSyncExternalStore } from "react";
import { Link, type AnyRouter } from "@tanstack/react-router";
import { useSettingsState } from "../context";
import { categoryRows, shownSidebarSections, type Category } from "../categories";
import { settingsFileName } from "../format";
import { Icon } from "../icons";
import type { SettingsState } from "../store";
import { managedOf } from "../store";
import { t, text } from "../strings";
import { harnessesNeedAttention } from "../harnesses";

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

/** The category list: icon, name, and a badge for problems (warning), managed keys (lock) or an
 * agent CLI that is outdated or signed out (update). Each entry is a router link: hover or keyboard
 * focus preloads its section (the router's `defaultPreload: "intent"`), a click navigates.
 * `current` marks the shown category (null while searching); the link's own active match is exact,
 * so it never marks a section the page is not showing. */
export function SectionList({ current, onSelect }: { current: string | null; onSelect: (section: string) => void }) {
  const state = useSettingsState();
  const link = (category: Category) => {
    const mark = badge(state, category.id);
    return (
      <Link<AnyRouter, string, string>
        key={category.id}
        to="/settings/$section"
        params={{ section: category.id }}
        search={{}}
        activeOptions={{ exact: true }}
        activeProps={{}}
        className="section-link"
        draggable={false}
        data-section-link={category.id}
        aria-current={category.id === current ? "page" : undefined}
        onClick={() => onSelect(category.id)}
      >
        <span className="section-icon" data-category={category.id}>
          <CategoryIcon symbol={category.symbol} />
        </span>
        <span className="section-name">{text(category.title)}</span>
        {mark && (
          <span className={`badge badge-${mark}`} data-badge={mark}>
            <Icon name={mark} />
            <span className="visually-hidden">
              {mark === "warning" ? t("settingsPage.problems", settingsFileName(state.host)) : t(BADGE_TEXT[mark])}
            </span>
          </span>
        )}
      </Link>
    );
  };
  // Each run of categories sits under its small header (Look and Feel, AI, ...), the layout the
  // Swift `SettingsPageLayout.sidebarSections` exports; the lead run (General, Updates) has none.
  return (
    <nav className="section-list" aria-label={t("settingsPage.sections")}>
      {shownSidebarSections(state.host?.dev_build === true).map(({ section, categories }) => {
        const headerId = `sidebar-section-${section.id}`;
        return (
          <div
            key={section.id}
            className="sidebar-section"
            data-sidebar-section={section.id}
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a labelled group of sidebar links; a fieldset would bring its own box and form semantics
            role="group"
            aria-labelledby={section.title ? headerId : undefined}
          >
            {section.title && (
              <h3 className="sidebar-section-title" id={headerId}>
                {text(section.title)}
              </h3>
            )}
            {categories.map(link)}
          </div>
        );
      })}
    </nav>
  );
}
