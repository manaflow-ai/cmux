// The gallery's stage and controls: a stage is an iframe of frame.html under the controls (in
// window mode the real-size window, scaled down by one transform); the controls edit the URL
// contract (env.ts). A developer tool: its own labels are English, like the native gallery's.
import { useCallback, useEffect, useRef, useState } from "react";
import {
  DEFAULT_ENV,
  DENSITIES,
  DYNAMIC_SIZES,
  frameQuery,
  LOCALES,
  NATIVE_WIDTHS,
  PSEUDO_LOCALES,
  SCALES,
  WIDTHS,
  widthPx,
  ZOOMS,
  type GalleryEnv,
} from "../env";
import { stageHeight, type GalleryEntry } from "../format";
import { themeIsDark } from "../theme/ghostty";
import type { PlayReport } from "../play";
import { entryPaneSize, fitScale, PANE_LAYOUTS, WINDOW_PRESETS, windowSize, type PaneLayout } from "../window";
import metrics from "virtual:cmux-gallery/metrics";
import themes from "virtual:cmux-gallery/themes";

const sum = (report: PlayReport, value: (step: PlayReport["steps"][number]) => number) =>
  report.steps.reduce((total, step) => total + value(step), 0);

/** One line per step: what it did and what it found (the play result's tooltip). */
function playDetail(report: PlayReport): string {
  return report.steps
    .map((step) => `${step.status} ${step.step}${step.problems.length ? `: ${step.problems.join("; ")}` : ""}`)
    .join("\n");
}

export const LOCALE_NAMES: Record<string, string> = {
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
export const SAMPLE_THEMES = [
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

/** The room a window has to fit in: the element's width, and the viewport height below its top
 * edge. Followed as the element or the window resizes (a callback ref, no effect). */
export function useRoom(): [(node: HTMLElement | null) => void, { width: number; height: number }] {
  const [room, setRoom] = useState({ width: 0, height: 0 });
  const ref = useCallback((node: HTMLElement | null) => {
    if (!node) return;
    const measure = () => {
      const rect = node.getBoundingClientRect();
      // The caption line above each window takes about 28 px.
      setRoom({ width: Math.floor(rect.width), height: Math.floor(innerHeight - Math.max(0, rect.top) - 44) });
    };
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    addEventListener("resize", measure);
    return () => {
      observer.disconnect();
      removeEventListener("resize", measure);
    };
  }, []);
  return [ref, room];
}

/** Grid views show windows as thumbnails this wide. */
const THUMBNAIL_WIDTH = 420;

export function Stage({
  entry,
  state,
  env,
  tune,
  label,
  available,
  thumbnail,
}: {
  entry: GalleryEntry;
  state: string;
  env: GalleryEnv;
  /** The edited tunables (router.tsx ShellSearch `tune`). */
  tune?: string;
  label?: string;
  available: { width: number; height: number };
  thumbnail: boolean;
}) {
  const query = frameQuery({ entry: entry.id, variant: state, tune }, env);
  // Replay mounts the stage again, so its play steps run from the start.
  const [run, setRun] = useState(0);
  const [report, setReport] = useState<PlayReport | undefined>();
  const hasPlay = Boolean(entry.variants[state]?.play);
  const note = entry.variants[state]?.note;
  // Component entries have their own natural bounds. Keep the window frame for page entries,
  // but never make a component preview inherit the 16:9 window's scale.
  const windowed = env.frame === "window" && entry.host !== "native" && entry.host !== "component";
  let frame: { width: number; height: number };
  let scale = 1;
  if (windowed) {
    // The surface lays out at the real size of its pane in that window; one transform scales the
    // finished surface, so its aspect ratio, text and spacing stay as the user sees them.
    frame = entryPaneSize(env.window, env.layout, env.density, metrics);
    scale = thumbnail ? THUMBNAIL_WIDTH / frame.width : env.zoom === "fit" ? fitScale(frame, available) : env.zoom;
  } else {
    // The pane's width; the interface scale zooms the page inside it, as pageZoom does.
    frame = {
      width: widthPx(env.width, entry.widths ?? (entry.host === "native" ? NATIVE_WIDTHS : WIDTHS)),
      height: env.height || stageHeight(entry, state),
    };
    scale = env.zoom === "fit" ? fitScale(frame, available) : env.zoom;
  }
  const frameWidth = frame.width;
  const frameHeight = frame.height;
  type FrameState = { query: string; run: number; frame: { width: number; height: number }; scale: number };
  const [display, setDisplay] = useState<FrameState>({ query, run, frame, scale });
  const [pending, setPending] = useState<FrameState>();
  const promotion = useRef(0);
  const pendingRef = useRef<FrameState | undefined>(undefined);
  pendingRef.current = pending;
  useEffect(() => {
    const requested = { query, run, frame: { width: frameWidth, height: frameHeight }, scale };
    if (display.query === query && display.run === run) {
      setDisplay((current) => ({ ...current, frame: requested.frame, scale }));
      setPending(undefined);
      return;
    }
    setPending((current) =>
      current?.query === requested.query &&
      current.run === requested.run &&
      current.frame.width === frameWidth &&
      current.frame.height === frameHeight &&
      current.scale === scale
        ? current
        : requested,
    );
  }, [display.query, display.run, frameHeight, frameWidth, query, run, scale]);
  const frameRef = useCallback(
    (iframe: HTMLIFrameElement | null) => {
      if (!iframe) return;
      const receive = (event: MessageEvent) => {
        const data = event.data as { type?: string; report?: PlayReport; status?: string } | null;
        const query = iframe.dataset.galleryQuery;
        const run = Number(iframe.dataset.galleryRun);
        if (event.source !== iframe.contentWindow || !query || !Number.isFinite(run)) return;
        if (data?.type === "cmux-gallery-play") setReport(data.report);
        if (data?.type === "cmux-gallery-stage" && (data.status === "ready" || data.status === "error")) {
          const pending = pendingRef.current;
          if (!pending || pending.query !== query || pending.run !== run) return;
          const token = ++promotion.current;
          requestAnimationFrame(() => {
            if (token !== promotion.current) return;
            const current = pendingRef.current;
            if (!current || current.query !== query || current.run !== run) return;
            pendingRef.current = undefined;
            setDisplay(current);
            setPending(undefined);
          });
        }
      };
      addEventListener("message", receive);
      return () => {
        removeEventListener("message", receive);
        promotion.current += 1;
      };
    },
    [],
  );
  const shown = display;
  const next = pending;
  const iframe = (content: typeof shown, hidden: boolean) => (
    <iframe
      key={`${content.run}:${content.query}`}
      ref={frameRef}
      data-gallery-query={content.query}
      data-gallery-run={content.run}
      title={`${entry.id} ${state}`}
      src={`frame.html?${content.query}`}
      style={{
        width: content.frame.width,
        height: content.frame.height,
        transform: `scale(${content.scale})`,
        background: "var(--g-bg)",
        ...(hidden ? { position: "absolute", inset: 0, opacity: 0, pointerEvents: "none" } : {}),
      }}
      loading="lazy"
    />
  );
  return (
    <figure className="gallery-stage">
      <figcaption>
        <strong>{label ?? state}</strong>
        {note && !thumbnail && <span className="gallery-note">{note}</span>}
        {windowed && (
          <span className="gallery-note">
            {WINDOW_PRESETS[env.window as keyof typeof WINDOW_PRESETS]?.label ?? env.window} window · pane {frame.width}
            ×{frame.height} pt · {Math.round(scale * 100)}%
          </span>
        )}
        <a href={`frame.html?${query}`} target="_blank" rel="noreferrer">
          open
        </a>
        {hasPlay && (
          <button
            type="button"
            className="gallery-replay"
            onClick={() => {
              setReport(undefined);
              setRun((count) => count + 1);
            }}
          >
            Replay
          </button>
        )}
        {report && (
          <span className={`gallery-play gallery-play--${report.status}`} title={playDetail(report)}>
            play {report.status} · CLS {sum(report, (step) => step.layoutShift).toFixed(3)} · long frames{" "}
            {sum(report, (step) => step.longFrames.length)}
            {report.error ? ` · ${report.error}` : ""}
          </span>
        )}
      </figcaption>
      <div
        className="gallery-window"
        style={{ width: shown.frame.width * shown.scale, height: shown.frame.height * shown.scale }}
      >
        {iframe(shown, false)}
        {next && iframe(next, true)}
      </div>
    </figure>
  );
}

export function Controls({ env, onChange }: { env: GalleryEnv; onChange: (env: GalleryEnv) => void }) {
  const set = <K extends keyof GalleryEnv>(key: K, value: GalleryEnv[K]) => onChange({ ...env, [key]: value });
  const darkThemes = themes.filter(themeIsDark);
  const lightThemes = themes.filter((theme) => !themeIsDark(theme));
  const themeOptions = (selected: string) => (
    <>
      <optgroup label={`Dark (${darkThemes.length})`}>
        {darkThemes.map((theme) => (
          <option key={theme.name} value={theme.name}>
            {theme.name}
          </option>
        ))}
      </optgroup>
      <optgroup label={`Light (${lightThemes.length})`}>
        {lightThemes.map((theme) => (
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
      <label>
        Theme
        <select value={env.theme} onChange={(event) => set("theme", event.target.value)}>
          {themeOptions(env.theme)}
        </select>
      </label>
      <fieldset className="gallery-segmented">
        <legend>Appearance</legend>
        {(["auto", "dark", "light"] as const).map((scheme) => (
          <label key={scheme}>
            <input
              type="radio"
              name="colorScheme"
              aria-label={`Appearance ${scheme}`}
              checked={env.colorScheme === scheme}
              onChange={() => set("colorScheme", scheme)}
            />
            {scheme}
          </label>
        ))}
      </fieldset>
      <label>
        Font
        <input
          list="gallery-fonts"
          aria-label="Font"
          value={env.fontFamily}
          placeholder="page default"
          onChange={(event) => set("fontFamily", event.target.value)}
        />
        <datalist id="gallery-fonts">
          {FONTS.filter(Boolean).map((font) => (
            <option key={font} value={font}>
              {font}
            </option>
          ))}
        </datalist>
      </label>
      <label>
        Size
        <input
          type="number"
          aria-label="Font size"
          min={0}
          max={40}
          value={env.fontSize || ""}
          placeholder="default"
          onChange={(event) => set("fontSize", Number(event.target.value) || 0)}
        />
      </label>
      <label>
        Density
        <select
          title="The window chrome's metrics (MetricTunables); web pages have no density input"
          value={env.density}
          onChange={(event) => set("density", event.target.value as GalleryEnv["density"])}
        >
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
      <fieldset className="gallery-segmented">
        <legend>Frame</legend>
        {(["window", "component"] as const).map((frame) => (
          <label key={frame}>
            <input
              type="radio"
              name="frame"
              aria-label={`Frame ${frame}`}
              checked={env.frame === frame}
              onChange={() => set("frame", frame)}
            />
            {frame}
          </label>
        ))}
      </fieldset>
      {env.frame === "window" && (
        <>
          <label>
            Window
            <select
              value={env.window in WINDOW_PRESETS ? env.window : "custom"}
              onChange={(event) =>
                set(
                  "window",
                  event.target.value === "custom"
                    ? `${windowSize(env.window).width}x${windowSize(env.window).height}`
                    : event.target.value,
                )
              }
            >
              {Object.entries(WINDOW_PRESETS).map(([name, preset]) => (
                <option key={name} value={name}>
                  {preset.label} ({preset.width}x{preset.height})
                </option>
              ))}
              <option value="custom">custom</option>
            </select>
            {!(env.window in WINDOW_PRESETS) && (
              <input
                value={env.window}
                aria-label="Custom window size"
                placeholder="1440x900"
                onChange={(event) => /^\d{3,4}x\d{3,4}$/.test(event.target.value) && set("window", event.target.value)}
              />
            )}
          </label>
          <label>
            Zoom
            <select
              value={String(env.zoom)}
              onChange={(event) => set("zoom", event.target.value === "fit" ? "fit" : Number(event.target.value))}
            >
              {(ZOOMS as readonly (string | number)[]).includes(env.zoom) ? null : (
                <option value={String(env.zoom)}>{env.zoom}</option>
              )}
              {ZOOMS.map((zoom) => (
                <option key={zoom} value={String(zoom)}>
                  {zoom === "fit" ? "fit" : `${Math.round(zoom * 100)}%`}
                </option>
              ))}
            </select>
          </label>
          <label>
            Panes
            <select value={env.layout} onChange={(event) => set("layout", event.target.value as PaneLayout)}>
              {Object.entries(PANE_LAYOUTS).map(([name, label]) => (
                <option key={name} value={name}>
                  {label}
                </option>
              ))}
            </select>
          </label>
        </>
      )}
      {env.frame === "component" && (
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
      )}
      <label title="Native only: web pages have no text size input">
        Dynamic size
        <select
          value={env.dynamicSize}
          onChange={(event) => set("dynamicSize", event.target.value as GalleryEnv["dynamicSize"])}
        >
          {DYNAMIC_SIZES.map((size) => (
            <option key={size}>{size}</option>
          ))}
        </select>
      </label>
      <label className="gallery-check" title="Native only">
        <input
          type="checkbox"
          aria-label="Inactive window"
          checked={env.windowKey === "inactive"}
          onChange={(event) => set("windowKey", event.target.checked ? "inactive" : "key")}
        />
        Inactive window
      </label>
      <label className="gallery-check">
        <input
          type="checkbox"
          aria-label="Reduce motion"
          checked={env.reducedMotion}
          onChange={(event) => set("reducedMotion", event.target.checked)}
        />
        Reduce motion
      </label>
      <label className="gallery-check">
        <input
          type="checkbox"
          aria-label="Increase contrast"
          checked={env.highContrast}
          onChange={(event) => set("highContrast", event.target.checked)}
        />
        Increase contrast
      </label>
      <button type="button" onClick={() => onChange(DEFAULT_ENV)}>
        Reset
      </button>
    </div>
  );
}
