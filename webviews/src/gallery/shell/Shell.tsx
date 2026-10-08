// The gallery shell: the entry list, the controls and the stages. Its whole state is the route
// (router.tsx: `#/<entry>/<variant>?<controls>`), so a link reproduces a view and Back and
// Forward walk the views. Each stage is an iframe of frame.html with the same controls, so a
// stage is isolated (its own document, globals, stylesheets and language) and is exactly what
// the matrix runner screenshots. The shell's own colors are the current theme's tokens.
import { useRouterState } from "@tanstack/react-router";
import { useMemo, useState, useSyncExternalStore, type ReactNode } from "react";
import { readyEntries, type EntryState } from "../entryStore";
import { LOCALES, PSEUDO_LOCALES, type GalleryEnv } from "../env";
import type { GalleryEntry } from "../format";
import { ageText, liveStatus, type LiveStatus } from "../liveStatus";
import { entryStore } from "../registry";
import { DEFAULT_DARK_THEME, themeIsDark } from "../theme/ghostty";
import { css } from "../theme/tokens";
import { themeTokens } from "../theme/web";
import themes from "virtual:cmux-gallery/themes";
import { EntryBoundary } from "./EntryBoundary";
import { createGalleryRouter, validateShellSearch, VIEWS, type ShellSearch, type View } from "./router";
import { GalleryVariantPick } from "./GalleryVariantPick";
import { CompareView } from "./CompareView";
import { BrowseView } from "./BrowseView";
import { Controls, SAMPLE_THEMES, Stage, useRoom } from "./Stage";
import { Tunables } from "./Tunables";
import { EXPERIMENTAL_AREA, sidebarGroups } from "./groups";
import { experimentalLabel } from "./strings";

const VIEW_LABELS: Record<View, string> = {
  variant: "Variant",
  variants: "All variants",
  locales: "All locales",
  themes: "Themes",
  compare: "Compare arms",
  browse: "Browse gallery",
};

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

/** Every entry file's load, re-rendered when one changes (entryStore.ts). */
function useEntryStates(): readonly EntryState[] {
  return useSyncExternalStore(entryStore.subscribe, entryStore.getSnapshot);
}

/** The entry a state stands for: the loaded one, else the last one that file loaded. */
const known = (state: EntryState): GalleryEntry | undefined => state.entry ?? state.lastGood;

/**
 * The current address: the route's params and validated search, and the entry file it names. A
 * broken file keeps its address (its last good id), so its error card shows where the entry was.
 */
function useAddress(states: readonly EntryState[]): Address & { state: EntryState | undefined } {
  const location = useRouterState({ router: router as never, select: (state) => state.location });
  return useMemo(() => {
    const [, entryId = "", variantId = ""] = location.pathname.split("/").map(decodeURIComponent);
    const named = states.find((state) => known(state)?.id === entryId);
    const fallback = sidebarGroups(states)
      .flatMap((group) => group.states)
      .find((state) => state.status === "ready" && state.entry);
    const state = named ?? fallback;
    const entry = state && known(state);
    const variants = entry ? Object.keys(entry.variants) : [];
    const variant = variants.includes(variantId) ? variantId : (variants[0] ?? variantId);
    const search = validateShellSearch(location.search as Record<string, unknown>);
    return { entry: entry?.id ?? entryId, variant, search, state };
  }, [location, states]);
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

function Sidebar({ address, states, status }: { address: Address; states: readonly EntryState[]; status: LiveStatus }) {
  const [filter, setFilter] = useState("");
  const [active, setActive] = useState(-1);
  const needle = filter.trim().toLowerCase();
  const entries = readyEntries(states);
  const groups = sidebarGroups(states);
  const experimental = experimentalLabel(address.search.locale);
  const entryMatches = (entry: GalleryEntry) =>
    !needle ||
    `${entry.area} ${entry.title} ${entry.id} ${entry.experimental ? experimental : ""}`.toLowerCase().includes(needle);
  const variantsOf = (entry: GalleryEntry) =>
    Object.keys(entry.variants).filter((variant) => entryMatches(entry) || variant.includes(needle));
  // The filter's arrow keys walk every visible variant in order; Return opens the active one.
  const flat = groups.flatMap((group) =>
    group.states.flatMap((state) =>
      state.status === "ready" && state.entry
        ? variantsOf(state.entry).map((variant) => ({ entry: state.entry!.id, variant }))
        : [],
    ),
  );
  const total = entries.reduce((sum, entry) => sum + Object.keys(entry.variants).length, 0);
  const open = (target: { entry: string; variant: string }) => go({ ...target, search: address.search });
  const browseSearch = { ...address.search, view: "browse" as const };
  return (
    <nav className="gallery-list" aria-label="Gallery entries">
      <div className="gallery-filter">
        <Revision status={status} />
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
        <a
          className="gallery-browse-link"
          href={href({ ...address, search: browseSearch })}
          aria-current={address.search.view === "browse" ? "page" : undefined}
          onClick={(event) => {
            event.preventDefault();
            go({ ...address, search: browseSearch });
          }}
        >
          Browse all {entries.length} entries
        </a>
      </div>
      {groups.map(({ area, states: all }) => {
        // A broken or loading file always shows (its card names the file); a loaded one when it matches.
        const items = all.filter((state) => state.status !== "ready" || variantsOf(state.entry!).length > 0);
        if (needle && items.length === 0) return null;
        const loaded = all.flatMap((state) => (state.entry ? [state.entry] : []));
        const variantCount = loaded.reduce((sum, entry) => sum + Object.keys(entry.variants).length, 0);
        return (
          <section key={area} className="gallery-group">
            <h2>
              {area === EXPERIMENTAL_AREA ? experimental : area}{" "}
              <span className="gallery-count">
                {all.length} · {variantCount}
              </span>
            </h2>
            {all.length === 0 && <p className="gallery-none">No entries yet</p>}
            {items.map((state) => (
              <EntryBoundary
                key={state.path}
                state={state}
                compact
                loading={<div className="gallery-entry gallery-entry-loading">{known(state)?.title ?? state.path}</div>}
                render={(entry) => (
                  <div className="gallery-entry">
                    <div className="gallery-entry-title">
                      <Highlight text={entry.title} needle={needle} />
                      <span className="gallery-entry-id">{entry.id}</span>
                    </div>
                    <ul className="gallery-variants">
                      {variantsOf(entry).map((variant) => {
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
                )}
              />
            ))}
          </section>
        );
      })}
    </nav>
  );
}

/** The commit the gallery serves and its age; `live` on the live dev server, `build` on a static one. */
function Revision({ status }: { status: LiveStatus }) {
  const now = useMinuteClock();
  const short = status.sha.slice(0, 12);
  const url = /^[0-9a-f]{40}$/.test(status.sha)
    ? `https://github.com/manaflow-ai/cmux/commit/${status.sha}`
    : undefined;
  return (
    <div className="gallery-revision" title={`${status.branch ? `${status.branch}: ` : ""}${status.subject}`}>
      <span className={status.live ? "gallery-revision-live" : undefined}>{status.live ? "live" : "build"}</span>{" "}
      {url ? (
        <a href={url} target="_blank" rel="noreferrer">
          <code>{short}</code>
        </a>
      ) : (
        <code>{short}</code>
      )}{" "}
      · {status.committedAt ? `${ageText(status.committedAt, now)} old` : "age unknown"}
    </div>
  );
}

/** Compile errors outside the shell (live server) and entry files that failed to load. */
function ErrorBanner({ states, status }: { states: readonly EntryState[]; status: LiveStatus }) {
  const failed = states.filter((state) => state.status === "error").map((state) => state.path);
  const compile = status.errors.filter(
    (error) => error.kind === "stage" || !failed.some((path) => error.entries.includes(path)),
  );
  if (failed.length === 0 && compile.length === 0) return null;
  return (
    <div className="gallery-banner" role="alert" data-gallery-banner="">
      <strong>
        {failed.length > 0 && `${failed.length} ${failed.length === 1 ? "entry does" : "entries do"} not load`}
        {failed.length > 0 && compile.length > 0 && " · "}
        {compile.length > 0 && `compile error in ${compile.length} ${compile.length === 1 ? "file" : "files"}`}
      </strong>
      : {[...failed, ...compile.map((error) => error.file)].join(", ")}. The other entries keep working.
    </div>
  );
}

/** Date.now(), re-read once a minute (the revision's age). */
let minuteNow = Date.now();
const minuteListeners = new Set<() => void>();
let minuteTimer: ReturnType<typeof setInterval> | undefined;
function subscribeMinute(listener: () => void): () => void {
  minuteListeners.add(listener);
  minuteTimer ??= setInterval(() => {
    minuteNow = Date.now();
    for (const each of minuteListeners) each();
  }, 30_000);
  return () => {
    minuteListeners.delete(listener);
    if (minuteListeners.size === 0 && minuteTimer !== undefined) {
      clearInterval(minuteTimer);
      minuteTimer = undefined;
    }
  };
}
const useMinuteClock = () => useSyncExternalStore(subscribeMinute, () => minuteNow);

/** The shell's chrome colors from the current theme (the gallery's own token pipeline). */
function shellColors(search: ShellSearch): Record<string, string> {
  const theme =
    themes.find((candidate) => candidate.name === search.theme) ??
    themes.find((candidate) => candidate.name === DEFAULT_DARK_THEME);
  if (!theme) return {};
  const tokens = themeTokens(theme);
  return {
    "--cmux-text": css(tokens.textPrimary),
    "--cmux-text-secondary": css(tokens.textSecondary),
    "--cmux-background": css(tokens.chromeBackground),
    "--cmux-separator": css(tokens.separator),
    "--cmux-hover": css(tokens.hoverFill),
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
  const states = useEntryStates();
  const status = useSyncExternalStore(liveStatus.subscribe, liveStatus.get);
  const address = useAddress(states);
  const { state, search } = address;
  return (
    <div className="gallery" style={shellColors(search)}>
      <Sidebar address={address} states={states} status={status} />
      <main className="gallery-main">
        <ErrorBanner states={states} status={status} />
        {state ? (
          <EntryBoundary
            key={state.path}
            state={state}
            loading={<p className="gallery-empty">Loading {state.path}</p>}
            render={(entry) => <EntryView entry={entry} address={address} states={states} />}
          />
        ) : states.length === 0 ? (
          <p className="gallery-empty">No gallery entries. Add a *.gallery.ts file.</p>
        ) : states.every((each) => each.status === "error") ? (
          <p className="gallery-empty">No entry loads. Each file's error is in the list.</p>
        ) : (
          <p className="gallery-empty">Loading</p>
        )}
      </main>
    </div>
  );
}

/** One entry's header and stages. */
function EntryView({
  entry,
  address,
  states,
}: {
  entry: GalleryEntry;
  address: Address;
  states: readonly EntryState[];
}) {
  const [stagesRef, room] = useRoom();
  const { search } = address;
  const variant = entry.variants[address.variant] ? address.variant : Object.keys(entry.variants)[0]!;
  const env: GalleryEnv = search;
  if (search.view === "browse") {
    return (
      <>
        <header className="gallery-header">
          <fieldset className="gallery-segmented">
            <legend>View</legend>
            {VIEWS.filter((view) => view !== "compare" || entry.experiment).map((view) => (
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
          <Controls
            env={env}
            onChange={(next) =>
              go(
                { ...address, search: { ...next, view: search.view, compare: search.compare, tune: search.tune } },
                true,
              )
            }
          />
        </header>
        <BrowseView
          entries={readyEntries(states)}
          env={env}
          tune={search.tune}
          available={{ width: Math.max(320, room.width - 4), height: Math.max(240, room.height) }}
          onOpen={(target, targetVariant) =>
            go({ entry: target.id, variant: targetVariant, search: { ...search, view: "variant" } })
          }
          hrefFor={(target, targetVariant) =>
            href({ entry: target.id, variant: targetVariant, search: { ...search, view: "variant" } })
          }
        />
      </>
    );
  }
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
    <>
      <header className="gallery-header">
        <h1>
          {entry.title} <small>{entry.id}</small> <small>· {variant}</small>
          {entry.experimental && <span className="gallery-experimental">{experimentalLabel(env.locale)}</span>}
        </h1>
        <fieldset className="gallery-segmented">
          <legend>View</legend>
          {VIEWS.filter((view) => view !== "compare" || entry.experiment).map((view) => (
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
        <Controls
          env={env}
          onChange={(next) =>
            go({ ...address, search: { ...next, view: search.view, compare: search.compare, tune: search.tune } }, true)
          }
        />
        {entry.tunables && entry.tunables.length > 0 && (
          <Tunables
            tunables={entry.tunables}
            tune={search.tune}
            onChange={(tune) => go({ ...address, search: { ...search, tune } }, true)}
          />
        )}
        <details className="gallery-covers">
          <summary>
            {entry.host} · covers {entry.covers.length}
          </summary>
          {entry.covers.join(", ")}
        </details>
      </header>
      <div ref={stagesRef} className={`gallery-stages gallery-stages--${search.view}`}>
        {entry.experiment && search.view === "compare" ? (
          <CompareView
            entry={entry}
            experiment={entry.experiment}
            variant={variant}
            env={env}
            tune={search.tune}
            compare={search.compare}
            room={room}
            onCompare={(compare, replace) => go({ ...address, search: { ...search, compare } }, replace)}
          />
        ) : entry.pick && search.view === "variants" ? (
          <GalleryVariantPick
            entry={entry}
            locale={env.locale}
            preview={(name) => (
              <Stage
                entry={entry}
                state={name}
                env={env}
                tune={search.tune}
                available={{ width: 420, height: room.height }}
                thumbnail
              />
            )}
          />
        ) : (
          stages.map((stage) => (
            <Stage
              key={stage.key}
              entry={entry}
              state={stage.variant}
              env={stage.env}
              tune={search.tune}
              label={stage.label}
              available={{ width: Math.max(320, room.width - 4), height: Math.max(240, room.height) }}
              thumbnail={search.view !== "variant"}
            />
          ))
        )}
      </div>
    </>
  );
}
