// l10n-allow-file: gallery prototype (sample labels), not shipped UI.
// Three ways to navigate Settings that push past "17 pages plus More 12" (findings G6,
// 2026-11-22): a search-first single scroll, six pages with progressive disclosure, and a
// command-palette Settings. Rows, groups, categories, counts and search results come from the real
// registry (model.ts); a row's control is drawn from its kind and default value only, since the
// question here is the navigation, not the controls. Opt-in gallery prototype: the shipped
// Settings page is unchanged.
import { Fragment, useMemo, useState, type ReactNode } from "react";
import { Icon } from "../../pages/settings/icons";
import { rowsByKey, type SchemaRow } from "../../pages/settings/schema";
import { queryTerms } from "../../pages/settings/search";
import { text } from "../../pages/settings/strings";
import type { Category } from "../../pages/settings/categories";
import {
  SIX_PAGES,
  controlOf,
  itemCount,
  pageCategories,
  pageOf,
  rowsOf,
  search,
  shown,
  totalRows,
  type SixPage,
} from "./model";
import "./settingsIA.css";

export type SettingsIALayout = "search-first" | "six-pages" | "palette";

export type SettingsIAProps = {
  layout: SettingsIALayout;
  /** The search text the variant opens with. */
  query?: string;
  /** Six pages: the page shown. */
  page?: string;
  /** Six pages: folded categories drawn open. */
  open?: string[];
  /** Palette: the selected result's row key. */
  selected?: string;
};

export function SettingsIA({ layout, query = "", page = "general", open = [], selected }: SettingsIAProps) {
  if (layout === "search-first") return <SearchFirst initialQuery={query} />;
  if (layout === "palette") return <Palette initialQuery={query} initialSelected={selected} />;
  return <SixPages initialPage={page} initialOpen={open} initialQuery={query} />;
}

/* Shared parts */

function Highlight({ value, terms }: { value: string; terms: string[] }) {
  if (terms.length === 0) return <>{value}</>;
  const pattern = new RegExp(`(${terms.map((term) => term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|")})`, "gi");
  return (
    <>
      {value.split(pattern).map((part, index) =>
        index % 2 === 1 ? (
          <mark key={index} className="sia-mark">
            {part}
          </mark>
        ) : (
          <Fragment key={index}>{part}</Fragment>
        ),
      )}
    </>
  );
}

function Control({ row }: { row: SchemaRow }) {
  const control = controlOf(row);
  if (control.kind === "switch")
    return <span className="sia-switch" data-on={control.on ? "" : undefined} aria-hidden />;
  if (control.kind === "popup")
    return (
      <span className="sia-popup">
        <span className="sia-popup-label">{control.label}</span>
        <Icon name="chevron.popup" />
      </span>
    );
  return <span className="sia-button">{control.label}</span>;
}

function Row({ row, terms = [], crumb }: { row: SchemaRow; terms?: string[]; crumb?: string }) {
  return (
    <div className="sia-row" data-key={row.key}>
      <div className="sia-row-text">
        {crumb && <div className="sia-crumb">{crumb}</div>}
        <div className="sia-row-title">
          <Highlight value={text(row.title)} terms={terms} />
        </div>
        {row.summary && (
          <div className="sia-row-summary">
            <Highlight value={text(row.summary)} terms={terms} />
          </div>
        )}
      </div>
      <Control row={row} />
    </div>
  );
}

function SearchBox({
  value,
  onChange,
  placeholder,
  size,
}: {
  value: string;
  onChange: (value: string) => void;
  placeholder: string;
  size?: "large";
}) {
  return (
    <label className="sia-search" data-size={size}>
      <Icon name="search" />
      <input
        value={value}
        placeholder={placeholder}
        onChange={(event) => onChange(event.target.value)}
        spellCheck={false}
      />
      {value && (
        <button type="button" className="sia-search-clear" aria-label="Clear" onClick={() => onChange("")}>
          <Icon name="xmark" />
        </button>
      )}
    </label>
  );
}

const crumbOf = (category: Category) => {
  const home = pageOf(category.id);
  return home.title === text(category.title) ? home.title : `${home.title} › ${text(category.title)}`;
};

function Results({ query }: { query: string }) {
  const terms = queryTerms(query);
  const groups = useMemo(() => search(query), [query]);
  const count = groups.reduce((sum, group) => sum + group.rows.length, 0);
  const pages = new Set(groups.map((group) => pageOf(group.category.id).id)).size;
  if (count === 0) return <div className="sia-empty">No settings match “{query}”.</div>;
  return (
    <div className="sia-results">
      <div className="sia-results-count">
        {count} {count === 1 ? "setting" : "settings"} on {pages} {pages === 1 ? "page" : "pages"}
      </div>
      {groups.map((group) => (
        <section key={group.category.id} className="sia-card">
          <h3 className="sia-card-title">{crumbOf(group.category)}</h3>
          {group.rows.map((row) => (
            <Row key={row.key} row={row} terms={terms} />
          ))}
        </section>
      ))}
    </div>
  );
}

/* (a) Search first, one scroll */

function SearchFirst({ initialQuery }: { initialQuery: string }) {
  const [query, setQuery] = useState(initialQuery);
  const [current, setCurrent] = useState(SIX_PAGES[0]!.id);
  const total = totalRows();
  return (
    <div className="sia sia-a">
      <header className="sia-a-head">
        <SearchBox value={query} onChange={setQuery} placeholder={`Search ${total} settings`} size="large" />
        {!query && (
          <nav className="sia-a-jump" aria-label="Jump to">
            {SIX_PAGES.map((page) => (
              <a
                key={page.id}
                href={`#sia-a-${page.id}`}
                className="sia-chip"
                aria-current={page.id === current ? "true" : undefined}
                onClick={() => setCurrent(page.id)}
              >
                <Icon name={page.symbol} />
                {page.title}
              </a>
            ))}
          </nav>
        )}
      </header>
      <div className="sia-a-body">
        {query ? (
          <Results query={query} />
        ) : (
          <div className="sia-a-scroll">
            {SIX_PAGES.map((page) => (
              <section key={page.id} id={`sia-a-${page.id}`} className="sia-a-page">
                <h2 className="sia-a-page-title">{page.title}</h2>
                {[...pageCategories(page, "essentials"), ...pageCategories(page, "folded")].map((category) => (
                  <section key={category.id} className="sia-card">
                    <h3 className="sia-card-title">{text(category.title)}</h3>
                    {rowsOf(category)
                      .slice(0, 6)
                      .map((row) => (
                        <Row key={row.key} row={row} />
                      ))}
                    {rowsOf(category).length > 6 && (
                      <div className="sia-more-line">
                        {rowsOf(category).length - 6} more in {text(category.title)}
                      </div>
                    )}
                  </section>
                ))}
              </section>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

/* (b) Six pages, progressive disclosure */

function Disclosure({ category, open, onToggle }: { category: Category; open: boolean; onToggle: () => void }) {
  const rows = rowsOf(category);
  const groups = category.groups.map((group) => text(group.title)).filter(Boolean);
  return (
    <div className="sia-fold" data-open={open ? "" : undefined}>
      <button type="button" className="sia-fold-head" aria-expanded={open} onClick={onToggle}>
        <span className="sia-fold-icon">
          <Icon name={category.symbol} />
        </span>
        <span className="sia-fold-text">
          <span className="sia-fold-title">{text(category.title)}</span>
          <span className="sia-fold-detail">
            {groups.length > 0 ? groups.slice(0, 4).join(", ") : "Opens its panel"}
          </span>
        </span>
        <span className="sia-fold-count">{itemCount(category)}</span>
        <Icon name="chevron" className="sia-fold-chevron" />
      </button>
      {open && (
        <div className="sia-fold-body">
          {category.groups.slice(0, 2).map((group) => (
            <section key={group.key} className="sia-card sia-card-inner">
              <h4 className="sia-card-title">{text(group.title)}</h4>
              {group.rows.slice(0, 5).map((row) => (
                <Row key={row.key} row={row} />
              ))}
            </section>
          ))}
          {rows.length > 0 && category.groups.length > 2 && (
            <div className="sia-more-line">
              {category.groups.length - 2} more groups in {text(category.title)}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function SixPages({
  initialPage,
  initialOpen,
  initialQuery,
}: {
  initialPage: string;
  initialOpen: string[];
  initialQuery: string;
}) {
  const [pageId, setPageId] = useState(initialPage);
  const [open, setOpen] = useState(() => new Set(initialOpen));
  const [query, setQuery] = useState(initialQuery);
  const page = SIX_PAGES.find((item) => item.id === pageId) ?? SIX_PAGES[0]!;
  const toggle = (id: string) =>
    setOpen((before) => {
      const next = new Set(before);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  return (
    <div className="sia sia-b">
      <aside className="sia-b-side">
        <div className="sia-b-heading">Settings</div>
        <SearchBox value={query} onChange={setQuery} placeholder="Search" />
        <nav className="sia-b-nav">
          {SIX_PAGES.map((item) => (
            <button
              type="button"
              key={item.id}
              className="sia-b-link"
              aria-current={!query && item.id === page.id ? "page" : undefined}
              onClick={() => {
                setQuery("");
                setPageId(item.id);
              }}
            >
              <Icon name={item.symbol} />
              <span>{item.title}</span>
            </button>
          ))}
        </nav>
      </aside>
      <main className="sia-b-main">
        {query ? <Results query={query} /> : <SixPageBody page={page} open={open} toggle={toggle} />}
      </main>
    </div>
  );
}

function SixPageBody({ page, open, toggle }: { page: SixPage; open: Set<string>; toggle: (id: string) => void }) {
  const essentials = pageCategories(page, "essentials");
  const folded = pageCategories(page, "folded");
  return (
    <>
      <h1 className="sia-b-title">{page.title}</h1>
      {essentials.map((category) => (
        <Essentials key={category.id} category={category} titled={essentials.length > 1} />
      ))}
      {folded.length > 0 && (
        <section className="sia-b-folded">
          {essentials.length > 0 && <h2 className="sia-b-subtitle">More</h2>}
          {folded.map((category) => (
            <Disclosure
              key={category.id}
              category={category}
              open={open.has(category.id)}
              onToggle={() => toggle(category.id)}
            />
          ))}
        </section>
      )}
    </>
  );
}

/** A category drawn open: its first two groups, the rest one click away. */
function Essentials({ category, titled }: { category: Category; titled: boolean }) {
  const [all, setAll] = useState(false);
  const groups = all ? category.groups : category.groups.slice(0, 2);
  const rest = category.groups.length - groups.length;
  return (
    <section className="sia-b-category">
      {titled && <h2 className="sia-b-subtitle">{text(category.title)}</h2>}
      {groups.map((group) => (
        <section key={group.key} className="sia-card">
          {group.title.text && <h3 className="sia-card-title">{text(group.title)}</h3>}
          {group.rows.slice(0, all ? undefined : 4).map((row) => (
            <Row key={row.key} row={row} />
          ))}
        </section>
      ))}
      {rest > 0 && (
        <button type="button" className="sia-show-all" onClick={() => setAll(true)}>
          Show all {text(category.title)} settings
          <span className="sia-show-all-detail">
            {rest} more {rest === 1 ? "group" : "groups"}:{" "}
            {category.groups
              .slice(2, 5)
              .map((group) => text(group.title))
              .join(", ")}
            {rest > 3 ? ", …" : ""}
          </span>
        </button>
      )}
    </section>
  );
}

/* (c) Settings as a command palette */

const SUGGESTED = [
  "appearance.metrics.chromeFontSize",
  "appearance.appTheme",
  "appearance.density",
  "notifications.sounds.when",
  "app.language",
];

type PaletteItem = { id: string; icon: string; title: string; crumb: string; row?: SchemaRow; page?: SixPage };

function Palette({ initialQuery, initialSelected }: { initialQuery: string; initialSelected?: string }) {
  const [query, setQuery] = useState(initialQuery);
  const terms = queryTerms(query);
  const sections = useMemo((): Array<{ title: string; items: PaletteItem[] }> => {
    const categories = new Map(
      shown().flatMap((category) => rowsOf(category).map((row) => [row.key, category] as const)),
    );
    const item = (row: SchemaRow): PaletteItem => {
      const category = categories.get(row.key);
      return {
        id: row.key,
        icon: category?.symbol ?? "gearshape",
        title: text(row.title),
        crumb: category ? crumbOf(category) : "",
        row,
      };
    };
    if (!query) {
      const suggested = SUGGESTED.flatMap((key) => {
        const row = rowsByKey.get(key);
        return row ? [item(row)] : [];
      });
      const pages = SIX_PAGES.map((page): PaletteItem => ({
        id: `page.${page.id}`,
        icon: page.symbol,
        title: page.title,
        crumb: [...pageCategories(page, "essentials"), ...pageCategories(page, "folded")]
          .slice(0, 4)
          .map((category) => text(category.title))
          .join(", "),
        page,
      }));
      return [
        { title: "Suggested", items: suggested },
        { title: "Open a page", items: pages },
      ];
    }
    const found = search(query).flatMap((group) => group.rows.map(item));
    return [{ title: `${found.length} settings`, items: found.slice(0, 40) }];
  }, [query]);
  const items = sections.flatMap((section) => section.items);
  const [selectedId, setSelectedId] = useState(initialSelected);
  const selected = items.find((entry) => entry.id === selectedId) ?? items[0];
  return (
    <div className="sia sia-c">
      <div className="sia-c-window" aria-hidden>
        <div className="sia-c-window-side" />
        <div className="sia-c-window-main" />
      </div>
      <div className="sia-c-palette" role="dialog" aria-label="Settings">
        <div className="sia-c-input">
          <Icon name="gearshape" />
          <input
            value={query}
            placeholder={`Change a setting… (${totalRows()})`}
            onChange={(event) => {
              setQuery(event.target.value);
              setSelectedId(undefined);
            }}
            spellCheck={false}
          />
          <kbd className="sia-kbd">⌘,</kbd>
        </div>
        <div className="sia-c-body">
          <div className="sia-c-list" role="listbox">
            {sections.map((section) => (
              <div key={section.title} className="sia-c-section">
                <div className="sia-c-section-title">{section.title}</div>
                {section.items.map((entry) => (
                  <button
                    type="button"
                    key={entry.id}
                    role="option"
                    aria-selected={entry === selected}
                    className="sia-c-item"
                    onClick={() => setSelectedId(entry.id)}
                  >
                    <Icon name={entry.icon} />
                    <span className="sia-c-item-text">
                      <span className="sia-c-item-title">
                        <Highlight value={entry.title} terms={terms} />
                      </span>
                      <span className="sia-c-item-crumb">{entry.crumb}</span>
                    </span>
                    {entry.row && <InlineValue row={entry.row} />}
                  </button>
                ))}
              </div>
            ))}
          </div>
          <div className="sia-c-detail">{selected && <Detail item={selected} />}</div>
        </div>
        <div className="sia-c-foot">
          <span>
            <kbd className="sia-kbd">↑↓</kbd> choose
          </span>
          <span>
            <kbd className="sia-kbd">↩</kbd> change
          </span>
          <span>
            <kbd className="sia-kbd">⌘↩</kbd> open its page
          </span>
        </div>
      </div>
    </div>
  );
}

function InlineValue({ row }: { row: SchemaRow }) {
  const control = controlOf(row);
  if (control.kind === "switch") return <span className="sia-c-value">{control.on ? "On" : "Off"}</span>;
  if (control.kind === "popup") return <span className="sia-c-value">{control.label}</span>;
  return null;
}

function Detail({ item }: { item: PaletteItem }): ReactNode {
  if (item.page) {
    const categories = [...pageCategories(item.page, "essentials"), ...pageCategories(item.page, "folded")];
    return (
      <div className="sia-c-detail-inner">
        <div className="sia-c-detail-crumb">Page</div>
        <div className="sia-c-detail-title">{item.page.title}</div>
        <ul className="sia-c-detail-list">
          {categories.map((category) => (
            <li key={category.id}>
              <Icon name={category.symbol} />
              {text(category.title)}
              <span className="sia-c-value">{itemCount(category)}</span>
            </li>
          ))}
        </ul>
      </div>
    );
  }
  const row = item.row!;
  return (
    <div className="sia-c-detail-inner">
      <div className="sia-c-detail-crumb">{item.crumb}</div>
      <div className="sia-c-detail-title">{text(row.title)}</div>
      {row.summary && <div className="sia-c-detail-summary">{text(row.summary)}</div>}
      <div className="sia-c-detail-control">
        <Control row={row} />
      </div>
      <div className="sia-c-detail-key">{row.key}</div>
    </div>
  );
}
