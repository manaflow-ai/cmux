// The gallery shell: the entry list, the controls and the stages. Its whole state is the URL
// query (env.ts plus `entry`, `state` and `view`), so a link reproduces a view. Each stage is an
// iframe of frame.html with the same query, so a stage is isolated (its own document, globals,
// stylesheets and language) and is exactly what the matrix runner screenshots. A developer tool:
// its own labels are English and not localized, like the native onboarding gallery's.
import { useMemo, useState, useSyncExternalStore } from "react";
import {
  DEFAULT_ENV,
  DENSITIES,
  frameQuery,
  DYNAMIC_SIZES,
  LOCALES,
  NATIVE_WIDTHS,
  PSEUDO_LOCALES,
  readEnv,
  SCALES,
  WIDTHS,
  widthPx,
  writeEnv,
  type GalleryEnv,
} from "../env";
import { stageHeight, type GalleryEntry } from "../format";
import { entries } from "../registry";
import { themeIsDark } from "../theme/ghostty";
import themes from "virtual:cmux-gallery/themes";

type View = "state" | "entry" | "locales" | "themes";
const VIEWS: { id: View; label: string }[] = [
  { id: "state", label: "Variant" },
  { id: "entry", label: "All variants" },
  { id: "locales", label: "All locales" },
  { id: "themes", label: "Themes" },
];

const LOCALE_NAMES: Record<string, string> = {
  en: "English",
  ar: "Arabic",
  bs: "Bosnian",
  da: "Danish",
  de: "German",
  es: "Spanish",
  fr: "French",
  it: "Italian",
  ja: "Japanese",
  km: "Khmer",
  ko: "Korean",
  nb: "Norwegian Bokmål",
  pl: "Polish",
  "pt-BR": "Portuguese (Brazil)",
  ru: "Russian",
  th: "Thai",
  tr: "Turkish",
  uk: "Ukrainian",
  vi: "Vietnamese",
  "zh-Hans": "Chinese (Simplified)",
  "zh-Hant": "Chinese (Traditional)",
  "en-XA": "Pseudo: long accented",
  "ar-XB": "Pseudo: right to left",
};

const FONTS = [
  "",
  "system-ui",
  '"SF Pro Text", system-ui',
  '"Helvetica Neue", Helvetica, sans-serif',
  "Georgia, serif",
  "ui-monospace, Menlo, monospace",
  '"JetBrains Mono", ui-monospace, monospace',
];

/** Themes the Themes view samples: the pair in use plus a spread of popular ones. */
const SAMPLE_THEMES = [
  "Apple System Colors",
  "Apple System Colors Light",
  "Dracula",
  "Nord",
  "Solarized Dark Higher Contrast",
  "Catppuccin Latte",
  "Gruvbox Dark",
  "Tokyo Night",
  "One Half Light",
  "Monokai Classic",
  "GitHub Light Default",
  "Rose Pine Dawn",
];

// The URL is the store: every control writes it with replaceState and the shell re-reads it.
const listeners = new Set<() => void>();
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  addEventListener("popstate", listener);
  return () => {
    listeners.delete(listener);
    removeEventListener("popstate", listener);
  };
};
const readSearch = () => location.search;
function navigate(params: URLSearchParams, push = false): void {
  const url = `${location.pathname}${params.size ? `?${params}` : ""}`;
  if (push) history.pushState(null, "", url);
  else history.replaceState(null, "", url);
  for (const listener of listeners) listener();
}

function useQuery() {
  const search = useSyncExternalStore(subscribe, readSearch);
  return useMemo(() => {
    const params = new URLSearchParams(search);
    const env = readEnv(params);
    const entry = entries.find((candidate) => candidate.id === params.get("entry")) ?? entries[0];
    const variants = entry ? Object.keys(entry.variants) : [];
    const state = variants.includes(params.get("variant") ?? "") ? params.get("variant")! : variants[0];
    const view = (VIEWS.find((candidate) => candidate.id === params.get("view"))?.id ?? "state") as View;
    return { params, env, entry, state, view };
  }, [search]);
}

function update(params: URLSearchParams, changes: Record<string, string | null>, push = false): void {
  const next = new URLSearchParams(params);
  for (const [key, value] of Object.entries(changes)) {
    if (value === null) next.delete(key);
    else next.set(key, value);
  }
  navigate(next, push);
}

function setEnv(params: URLSearchParams, env: GalleryEnv): void {
  navigate(writeEnv(env, new URLSearchParams(params)));
}

function Stage({
  entry,
  state,
  env,
  label,
}: {
  entry: GalleryEntry;
  state: string;
  env: GalleryEnv;
  label?: string;
}) {
  const query = frameQuery({ entry: entry.id, variant: state }, env);
  // The pane's width; the interface scale zooms the page inside it, as pageZoom does.
  const width = widthPx(env.width, entry.widths ?? (entry.host === "native" ? NATIVE_WIDTHS : WIDTHS));
  const height = env.height || stageHeight(entry, state);
  const note = entry.variants[state]?.note;
  return (
    <figure className="gallery-stage">
      <figcaption>
        <strong>{label ?? state}</strong>
        {note && <span className="gallery-note">{note}</span>}
        <a href={`frame.html?${query}`} target="_blank" rel="noreferrer">
          open
        </a>
      </figcaption>
      <iframe
        title={`${entry.id} ${state}`}
        src={`frame.html?${query}`}
        style={{ width, height }}
        loading="lazy"
      />
    </figure>
  );
}

function Controls({ params, env }: { params: URLSearchParams; env: GalleryEnv }) {
  const set = <K extends keyof GalleryEnv>(key: K, value: GalleryEnv[K]) => setEnv(params, { ...env, [key]: value });
  const darkThemes = themes.filter(themeIsDark);
  const lightThemes = themes.filter((theme) => !themeIsDark(theme));
  const themeOptions = (selected: string, preferDark: boolean) => (
    <>
      <optgroup label={preferDark ? `Dark (${darkThemes.length})` : `Light (${lightThemes.length})`}>
        {(preferDark ? darkThemes : lightThemes).map((theme) => (
          <option key={theme.name} value={theme.name}>
            {theme.name}
          </option>
        ))}
      </optgroup>
      <optgroup label={preferDark ? "Light" : "Dark"}>
        {(preferDark ? lightThemes : darkThemes).map((theme) => (
          <option key={theme.name} value={theme.name}>
            {theme.name}
          </option>
        ))}
      </optgroup>
      {!themes.some((theme) => theme.name === selected) && <option value={selected}>{selected} (missing)</option>}
    </>
  );
  return (
    <div className="gallery-controls">
      <label>
        Locale
        <select value={env.locale} onChange={(event) => set("locale", event.target.value)}>
          {[...LOCALES, ...PSEUDO_LOCALES].map((locale) => (
            <option key={locale} value={locale}>
              {locale} · {LOCALE_NAMES[locale]}
            </option>
          ))}
        </select>
      </label>
      <fieldset className="gallery-segmented">
        <legend>Appearance</legend>
        {(["dark", "light"] as const).map((scheme) => (
          <label key={scheme}>
            <input
              type="radio"
              name="scheme"
              checked={env.scheme === scheme}
              onChange={() => set("scheme", scheme)}
            />
            {scheme}
          </label>
        ))}
      </fieldset>
      <label>
        Dark theme
        <select value={env.dark} onChange={(event) => set("dark", event.target.value)}>
          {themeOptions(env.dark, true)}
        </select>
      </label>
      <label>
        Light theme
        <select value={env.light} onChange={(event) => set("light", event.target.value)}>
          {themeOptions(env.light, false)}
        </select>
      </label>
      <label>
        Font
        <input
          list="gallery-fonts"
          value={env.font}
          placeholder="page default"
          onChange={(event) => set("font", event.target.value)}
        />
        <datalist id="gallery-fonts">
          {FONTS.filter(Boolean).map((font) => (
            <option key={font} value={font} />
          ))}
        </datalist>
      </label>
      <label>
        Size
        <input
          type="number"
          min={0}
          max={40}
          value={env.size || ""}
          placeholder="default"
          onChange={(event) => set("size", Number(event.target.value) || 0)}
        />
      </label>
      <label>
        Density
        <select title="Native only: web pages have no density input" value={env.density} onChange={(event) => set("density", event.target.value as GalleryEnv["density"])}>
          {DENSITIES.map((density) => (
            <option key={density}>{density}</option>
          ))}
        </select>
      </label>
      <label>
        Scale
        <select value={env.scale} onChange={(event) => set("scale", Number(event.target.value))}>
          {(SCALES as readonly number[]).includes(env.scale) ? null : <option value={env.scale}>{env.scale}</option>}
          {SCALES.map((scale) => (
            <option key={scale} value={scale}>
              {Math.round(scale * 100)}%
            </option>
          ))}
        </select>
      </label>
      <label>
        Width
        <select
          value={typeof env.width === "number" ? "custom" : env.width}
          onChange={(event) =>
            set(
              "width",
              event.target.value === "custom" ? widthPx(env.width) : (event.target.value as keyof typeof WIDTHS),
            )
          }
        >
          {Object.entries(WIDTHS).map(([name, px]) => (
            <option key={name} value={name}>
              {name} ({px})
            </option>
          ))}
          <option value="custom">custom</option>
        </select>
        {typeof env.width === "number" && (
          <input
            type="number"
            min={240}
            max={3000}
            value={env.width}
            aria-label="Custom width"
            onChange={(event) => set("width", Number(event.target.value) || 760)}
          />
        )}
      </label>
      <label title="Native only: web pages have no text size input">
        Dynamic size
        <select value={env.dynamicSize} onChange={(event) => set("dynamicSize", event.target.value as GalleryEnv["dynamicSize"])}>
          {DYNAMIC_SIZES.map((size) => (
            <option key={size}>{size}</option>
          ))}
        </select>
      </label>
      <label className="gallery-check" title="Native only">
        <input
          type="checkbox"
          checked={env.windowKey === "inactive"}
          onChange={(event) => set("windowKey", event.target.checked ? "inactive" : "key")}
        />
        Inactive window
      </label>
      <label className="gallery-check">
        <input type="checkbox" checked={env.reducedMotion} onChange={(event) => set("reducedMotion", event.target.checked)} />
        Reduce motion
      </label>
      <label className="gallery-check">
        <input type="checkbox" checked={env.highContrast} onChange={(event) => set("highContrast", event.target.checked)} />
        Increase contrast
      </label>
      <button type="button" onClick={() => setEnv(params, DEFAULT_ENV)}>
        Reset
      </button>
    </div>
  );
}

function EntryList({
  params,
  current,
  state,
}: {
  params: URLSearchParams;
  current: GalleryEntry | undefined;
  state: string | undefined;
}) {
  const [filter, setFilter] = useState("");
  const needle = filter.trim().toLowerCase();
  const visible = entries.filter(
    (entry) =>
      !needle ||
      `${entry.area} ${entry.title} ${entry.id} ${Object.keys(entry.variants).join(" ")}`.toLowerCase().includes(needle),
  );
  const areas = [...new Set(visible.map((entry) => entry.area))];
  const variantCount = entries.reduce((count, entry) => count + Object.keys(entry.variants).length, 0);
  return (
    <nav className="gallery-list" aria-label="Gallery entries">
      <input
        type="search"
        placeholder={`Filter ${entries.length} entries, ${variantCount} variants`}
        value={filter}
        onChange={(event) => setFilter(event.target.value)}
      />
      {areas.map((area) => (
        <section key={area}>
          <h2>{area}</h2>
          {visible
            .filter((entry) => entry.area === area)
            .map((entry) => (
              <details key={entry.id} open={entry === current}>
                <summary>
                  <a
                    href={`?${new URLSearchParams({ ...Object.fromEntries(params), entry: entry.id })}`}
                    aria-current={entry === current && !state ? "page" : undefined}
                    onClick={(event) => {
                      event.preventDefault();
                      update(params, { entry: entry.id, variant: null }, true);
                    }}
                  >
                    {entry.title}
                  </a>
                </summary>
                <ul>
                  {Object.keys(entry.variants).map((name) => (
                    <li key={name}>
                      <a
                        href={`?${new URLSearchParams({ ...Object.fromEntries(params), entry: entry.id, variant: name })}`}
                        aria-current={entry === current && name === state ? "page" : undefined}
                        onClick={(event) => {
                          event.preventDefault();
                          update(params, { entry: entry.id, variant: name }, true);
                        }}
                      >
                        {name}
                      </a>
                    </li>
                  ))}
                </ul>
              </details>
            ))}
        </section>
      ))}
    </nav>
  );
}

export function Shell() {
  const { params, env, entry, state, view } = useQuery();
  if (!entry || !state) return <p className="gallery-empty">No gallery entries. Add a *.gallery.ts file.</p>;
  let stages: { key: string; state: string; env: GalleryEnv; label?: string }[];
  switch (view) {
    case "entry":
      stages = Object.keys(entry.variants).map((name) => ({ key: name, state: name, env }));
      break;
    case "locales":
      stages = [...LOCALES, ...PSEUDO_LOCALES].map((locale) => ({
        key: locale,
        state,
        env: { ...env, locale },
        label: `${state} · ${locale}`,
      }));
      break;
    case "themes":
      stages = SAMPLE_THEMES.filter((name) => themes.some((theme) => theme.name === name)).map((name) => {
        const dark = themeIsDark(themes.find((theme) => theme.name === name)!);
        return {
          key: name,
          state,
          env: dark ? { ...env, scheme: "dark" as const, dark: name } : { ...env, scheme: "light" as const, light: name },
          label: `${state} · ${name}`,
        };
      });
      break;
    default:
      stages = [{ key: state, state, env }];
  }
  return (
    <div className="gallery">
      <EntryList params={params} current={entry} state={params.get("variant") ? state : undefined} />
      <main className="gallery-main">
        <header className="gallery-header">
          <h1>
            {entry.title} <small>{entry.id}</small>
          </h1>
          <fieldset className="gallery-segmented">
            <legend>View</legend>
            {VIEWS.map((candidate) => (
              <label key={candidate.id}>
                <input
                  type="radio"
                  name="view"
                  checked={view === candidate.id}
                  onChange={() => update(params, { view: candidate.id === "state" ? null : candidate.id })}
                />
                {candidate.label}
              </label>
            ))}
          </fieldset>
          <Controls params={params} env={env} />
          <p className="gallery-covers">
            {entry.host} · covers {entry.covers.join(", ")}
          </p>
        </header>
        <div className={`gallery-stages gallery-stages--${view}`}>
          {stages.map((stage) => (
            <Stage key={stage.key} entry={entry} state={stage.state} env={stage.env} label={stage.label} />
          ))}
        </div>
      </main>
    </div>
  );
}
