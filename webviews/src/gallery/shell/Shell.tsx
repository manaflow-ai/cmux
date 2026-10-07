// The gallery shell: the entry list, the controls and the stages. Its whole state is the route
// (router.tsx: `#/<entry>/<variant>?<controls>`), so a link reproduces a view and Back and
// Forward walk the views. Each stage is an iframe of frame.html with the same controls, so a
// stage is isolated (its own document, globals, stylesheets and language) and is exactly what
// the matrix runner screenshots. The shell's own colors are the current theme's tokens.
import { useRouterState } from "@tanstack/react-router";
import { useMemo, useState, type ReactNode } from "react";
import { LOCALES, PSEUDO_LOCALES, type GalleryEnv } from "../env";
import type { GalleryEntry } from "../format";
import { entries } from "../registry";
import { DEFAULT_DARK_THEME, themeIsDark } from "../theme/ghostty";
import { css } from "../theme/tokens";
import { themeTokens } from "../theme/web";
import themes from "virtual:cmux-gallery/themes";
import { createGalleryRouter, validateShellSearch, VIEWS, type ShellSearch, type View } from "./router";
import { Controls, SAMPLE_THEMES, Stage, useRoom } from "./Stage";

const VIEW_LABELS: Record<View, string> = {
  variant: "Variant",
  variants: "All variants",
  locales: "All locales",
  themes: "Themes",
};

/** The sidebar's groups, in this order; an area no entry names yet still shows, at 0. */
const AREAS = ["Agent pane", "New Tab", "Pages", "Home and Chief", "Settings", "Native"];

export const { router } = createGalleryRouter(Layout);

type Address = { entry: string; variant: string; search: ShellSearch };

function href({ entry, variant, search }: Address): string {
  const location = router.buildLocation({
    to: `/${encodeURIComponent(entry)}/${encodeURIComponent(variant)}`,
    search,
  } as never);
  return router.history.createHref(location.href);
}

function go({ entry, variant, search }: Address, replace = false): void {
  void router.navigate({
    to: `/${encodeURIComponent(entry)}/${encodeURIComponent(variant)}`,
    search,
    replace,
  } as never);
}

/** The current address: the route's params and validated search. */
function useAddress(): Address & { entryValue: GalleryEntry | undefined } {
  const location = useRouterState({ router: router as never, select: (state) => state.location });
  return useMemo(() => {
    const [, entryId = "", variantId = ""] = location.pathname.split("/").map(decodeURIComponent);
    const entry = entries.find((candidate) => candidate.id === entryId) ?? entries[0];
    const variants = entry ? Object.keys(entry.variants) : [];
    const variant = variants.includes(variantId) ? variantId : (variants[0] ?? "");
    const search = validateShellSearch(location.search as Record<string, unknown>);
    return { entry: entry?.id ?? "", variant, search, entryValue: entry };
  }, [location]);
}

/** Text with the filter's match marked. */
function Highlight({ text, needle }: { text: string; needle: string }): ReactNode {
  const at = needle ? text.toLowerCase().indexOf(needle) : -1;
  if (at < 0) return text;
  return (
    <>
      {text.slice(0, at)}
      <mark>{text.slice(at, at + needle.length)}</mark>
      {text.slice(at + needle.length)}
    </>
  );
}

/** Scrolls the current (or keyboard-active) chip into view when it mounts or becomes current. */
const reveal = (node: HTMLElement | null) => node?.scrollIntoView({ block: "nearest" });

function Sidebar({ address }: { address: Address }) {
  const [filter, setFilter] = useState("");
  const [active, setActive] = useState(-1);
  const needle = filter.trim().toLowerCase();
  const entryMatches = (entry: GalleryEntry) =>
    !needle || `${entry.area} ${entry.title} ${entry.id}`.toLowerCase().includes(needle);
  const visible = entries
    .map((entry) => ({
      entry,
      variants: Object.keys(entry.variants).filter((variant) => entryMatches(entry) || variant.includes(needle)),
    }))
    .filter((item) => item.variants.length > 0);
  // The filter's arrow keys walk every visible variant in order; Return opens the active one.
  const flat = visible.flatMap((item) => item.variants.map((variant) => ({ entry: item.entry.id, variant })));
  const areas = [...AREAS, ...new Set(entries.map((entry) => entry.area).filter((area) => !AREAS.includes(area)))];
  const total = entries.reduce((sum, entry) => sum + Object.keys(entry.variants).length, 0);
  const open = (target: { entry: string; variant: string }) => go({ ...target, search: address.search });
  return (
    <nav className="gallery-list" aria-label="Gallery entries">
      <div className="gallery-filter">
        <input
          type="search"
          placeholder={`Filter ${entries.length} entries, ${total} variants`}
          value={filter}
          aria-label="Filter entries and variants"
          onChange={(event) => {
            setFilter(event.target.value);
            setActive(-1);
          }}
          // ui-allow: the gallery's own filter field moves through its result list (a dev tool).
          onKeyDown={(event) => {
            if (event.key === "ArrowDown" || event.key === "ArrowUp") {
              event.preventDefault();
              const step = event.key === "ArrowDown" ? 1 : -1;
              setActive((current) => Math.max(0, Math.min(flat.length - 1, current + step)));
            } else if (event.key === "Enter" && flat.length) {
              open(flat[Math.max(0, active)]!);
            }
          }}
        />
      </div>
      {areas.map((area) => {
        const items = visible.filter((item) => item.entry.area === area);
        const all = entries.filter((entry) => entry.area === area);
        if (needle && items.length === 0) return null;
        const variantCount = all.reduce((sum, entry) => sum + Object.keys(entry.variants).length, 0);
        return (
          <section key={area} className="gallery-group">
            <h2>
              {area}{" "}
              <span className="gallery-count">
                {all.length} · {variantCount}
              </span>
            </h2>
            {all.length === 0 && <p className="gallery-none">No entries yet</p>}
            {items.map(({ entry, variants }) => (
              <div key={entry.id} className="gallery-entry">
                <div className="gallery-entry-title">
                  <Highlight text={entry.title} needle={needle} />
                  <span className="gallery-entry-id">{entry.id}</span>
                </div>
                <ul className="gallery-variants">
                  {variants.map((variant) => {
                    const current = entry.id === address.entry && variant === address.variant;
                    const index = flat.findIndex((item) => item.entry === entry.id && item.variant === variant);
                    return (
                      <li key={variant}>
                        <a
                          ref={current || index === active ? reveal : undefined}
                          href={href({ entry: entry.id, variant, search: address.search })}
                          aria-current={current ? "page" : undefined}
                          data-active={index === active ? "" : undefined}
                          onClick={(event) => {
                            event.preventDefault();
                            open({ entry: entry.id, variant });
                          }}
                        >
                          <Highlight text={variant} needle={needle} />
                        </a>
                      </li>
                    );
                  })}
                </ul>
              </div>
            ))}
          </section>
        );
      })}
    </nav>
  );
}

/** The shell's chrome colors from the current theme (the gallery's own token pipeline). */
function shellColors(search: ShellSearch): Record<string, string> {
  const theme =
    themes.find((candidate) => candidate.name === search.theme) ??
    themes.find((candidate) => candidate.name === DEFAULT_DARK_THEME);
  if (!theme) return {};
  const tokens = themeTokens(theme);
  return {
    "--g-bg": css({ ...tokens.windowBackground, alpha: 1 }),
    "--g-panel": css(tokens.chromeBackground),
    "--g-text": css(tokens.textPrimary),
    "--g-muted": css(tokens.textSecondary),
    "--g-line": css(tokens.separator),
    "--g-current": css(tokens.selectionFill),
    "--g-hover": css(tokens.hoverFill),
    "--g-mark": css({ ...tokens.attention, alpha: 0.35 }),
    colorScheme: themeIsDark(theme) ? "dark" : "light",
  };
}

function Layout() {
  const address = useAddress();
  const [stagesRef, room] = useRoom();
  const { entryValue: entry, variant, search } = address;
  if (!entry || !variant) return <p className="gallery-empty">No gallery entries. Add a *.gallery.ts file.</p>;
  const env: GalleryEnv = search;
  let stages: { key: string; variant: string; env: GalleryEnv; label?: string }[];
  switch (search.view) {
    case "variants":
      stages = Object.keys(entry.variants).map((name) => ({ key: name, variant: name, env }));
      break;
    case "locales":
      stages = [...LOCALES, ...PSEUDO_LOCALES].map((locale) => ({
        key: locale,
        variant,
        env: { ...env, locale },
        label: `${variant} · ${locale}`,
      }));
      break;
    case "themes":
      stages = SAMPLE_THEMES.filter((name) => themes.some((theme) => theme.name === name)).map((name) => ({
        key: name,
        variant,
        env: { ...env, theme: name, colorScheme: "auto" as const },
        label: `${variant} · ${name}`,
      }));
      break;
    default:
      stages = [{ key: variant, variant, env }];
  }
  return (
    <div className="gallery" style={shellColors(search)}>
      <Sidebar address={address} />
      <main className="gallery-main">
        <header className="gallery-header">
          <h1>
            {entry.title} <small>{entry.id}</small> <small>· {variant}</small>
          </h1>
          <fieldset className="gallery-segmented">
            <legend>View</legend>
            {VIEWS.map((view) => (
              <label key={view}>
                <input
                  type="radio"
                  name="view"
                  aria-label={VIEW_LABELS[view]}
                  checked={search.view === view}
                  onChange={() => go({ ...address, search: { ...search, view } })}
                />
                {VIEW_LABELS[view]}
              </label>
            ))}
          </fieldset>
          <Controls env={env} onChange={(next) => go({ ...address, search: { ...next, view: search.view } }, true)} />
          <details className="gallery-covers">
            <summary>
              {entry.host} · covers {entry.covers.length}
            </summary>
            {entry.covers.join(", ")}
          </details>
        </header>
        <div ref={stagesRef} className={`gallery-stages gallery-stages--${search.view}`}>
          {stages.map((stage) => (
            <Stage
              key={stage.key}
              entry={entry}
              state={stage.variant}
              env={stage.env}
              label={stage.label}
              available={{ width: Math.max(320, room.width - 4), height: Math.max(240, room.height) }}
              thumbnail={search.view !== "variant"}
            />
          ))}
        </div>
      </main>
    </div>
  );
}
