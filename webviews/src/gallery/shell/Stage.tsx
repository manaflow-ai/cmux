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
import {
  readScrollPosition,
  restoreScrollPosition,
  restoreScrollPositionUnlessMoved,
  SCROLL_KEYS,
  scrollStateAfterEvent,
  scrollTargetFor,
} from "./scroll";
import metrics from "virtual:cmux-gallery/metrics";
import themes from "virtual:cmux-gallery/themes";
import { Popover } from "../../ui/Popover";
import { Select } from "../../ui/Select";

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
 * edge. Followed as the element or the window resizes. */
export function useRoom(): [(node: HTMLElement | null) => void, { width: number; height: number }] {
  const [room, setRoom] = useState({ width: 0, height: 0 });
  const [node, setNode] = useState<HTMLElement | null>(null);
  useEffect(() => {
    if (!node) return;
    const measure = () => {
      const rect = node.getBoundingClientRect();
      // The caption line above each window takes about 28 px.
      setRoom({ width: Math.floor(rect.width), height: Math.floor(innerHeight - Math.max(0, rect.top) - 44) });
    };
    measure();
    const observer = typeof ResizeObserver === "undefined" ? undefined : new ResizeObserver(measure);
    observer?.observe(node);
    addEventListener("resize", measure);
    return () => {
      observer?.disconnect();
      removeEventListener("resize", measure);
    };
  }, [node]);
  return [setNode, room];
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
    const thumbnailWidth = Math.min(THUMBNAIL_WIDTH, available.width);
    scale = thumbnail ? thumbnailWidth / frame.width : env.zoom === "fit" ? fitScale(frame, available) : env.zoom;
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
  const frameRef = useCallback((iframe: HTMLIFrameElement | null) => {
    if (!iframe) return;
    const scrollTarget = scrollTargetFor(iframe);
    let baseline = readScrollPosition(scrollTarget);
    let restored = false;
    let userMoved = false;
    let intentPending = false;
    let pointerIntent = false;
    let intentFrame = 0;
    const intentTarget: EventTarget = scrollTarget ?? window;
    const parentWindow = iframe.ownerDocument.defaultView;
    const frameWindow = iframe.contentWindow;
    const uniqueEventTargets = (targets: (EventTarget | null)[]): EventTarget[] =>
      Array.from(new Set(targets.filter((target): target is EventTarget => target !== null)));
    const intentSources = uniqueEventTargets([intentTarget, frameWindow]);
    const keyboardSources = uniqueEventTargets([parentWindow, frameWindow]);
    const expireTransientIntent = () => {
      if (pointerIntent) return;
      intentPending = false;
    };
    const scheduleTransientIntentExpiry = () => {
      if (intentFrame) cancelAnimationFrame(intentFrame);
      intentFrame = requestAnimationFrame(() => {
        intentFrame = 0;
        expireTransientIntent();
      });
    };
    const markTransientIntent = () => {
      intentPending = true;
      scheduleTransientIntentExpiry();
    };
    const markPointerIntent = (event: Event) => {
      if ((event as PointerEvent).buttons > 0) {
        pointerIntent = true;
        intentPending = true;
      }
    };
    const clearPointerIntent = () => {
      pointerIntent = false;
      if (!userMoved) intentPending = false;
    };
    const markKeyboardIntent = (event: Event) => {
      if (SCROLL_KEYS.has((event as KeyboardEvent).key)) markTransientIntent();
    };
    const addIntentListener = (
      sources: EventTarget[],
      type: string,
      listener: EventListener,
      options?: AddEventListenerOptions | boolean,
    ) => {
      for (const source of sources) source.addEventListener(type, listener, options);
    };
    const removeIntentListener = (
      sources: EventTarget[],
      type: string,
      listener: EventListener,
      options?: EventListenerOptions | boolean,
    ) => {
      for (const source of sources) source.removeEventListener(type, listener, options);
    };
    addIntentListener(intentSources, "wheel", markTransientIntent, { passive: true, capture: true });
    addIntentListener(intentSources, "touchmove", markTransientIntent, { passive: true, capture: true });
    addIntentListener(intentSources, "pointermove", markPointerIntent, { passive: true, capture: true });
    addIntentListener(intentSources, "pointerup", clearPointerIntent, { passive: true, capture: true });
    addIntentListener(intentSources, "pointercancel", clearPointerIntent, { passive: true, capture: true });
    addIntentListener(keyboardSources, "keydown", markKeyboardIntent, true);
    const onScroll = () => {
      const result = scrollStateAfterEvent(scrollTarget, iframe, baseline, userMoved, intentPending);
      baseline = result.baseline;
      userMoved = result.userMoved;
      intentPending = result.intentPending;
      if (result.restore) restoreScrollPosition(scrollTarget, baseline);
    };
    intentTarget.addEventListener("scroll", onScroll, { passive: true });
    const removeIntentListeners = () => {
      if (intentFrame) cancelAnimationFrame(intentFrame);
      removeIntentListener(intentSources, "wheel", markTransientIntent, true);
      removeIntentListener(intentSources, "touchmove", markTransientIntent, true);
      removeIntentListener(intentSources, "pointermove", markPointerIntent, true);
      removeIntentListener(intentSources, "pointerup", clearPointerIntent, true);
      removeIntentListener(intentSources, "pointercancel", clearPointerIntent, true);
      removeIntentListener(keyboardSources, "keydown", markKeyboardIntent, true);
      intentTarget.removeEventListener("scroll", onScroll);
    };
    const restore = () => {
      if (restored) return;
      restored = true;
      restoreScrollPositionUnlessMoved(scrollTarget, baseline, userMoved);
      removeIntentListeners();
    };
    const receive = (event: MessageEvent) => {
      const data = event.data as { type?: string; report?: PlayReport; status?: string } | null;
      const query = iframe.dataset.galleryQuery;
      const run = Number(iframe.dataset.galleryRun);
      if (event.source !== iframe.contentWindow || !query || !Number.isFinite(run)) return;
      if (data?.type === "cmux-gallery-play") setReport(data.report);
      if (data?.type === "cmux-gallery-stage" && (data.status === "ready" || data.status === "error")) {
        restore();
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
      removeIntentListeners();
      promotion.current += 1;
    };
  }, []);
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
  const [moreOpen, setMoreOpen] = useState(false);
  const [moreAnchor, setMoreAnchor] = useState<HTMLButtonElement | null>(null);
  const moreButtonRef = useRef<HTMLButtonElement>(null);
  const darkThemes = themes.filter(themeIsDark);
  const lightThemes = themes.filter((theme) => !themeIsDark(theme));
  const themeOptions = [
    ...darkThemes.map((theme) => ({ value: theme.name, label: `Dark · ${theme.name}` })),
    ...lightThemes.map((theme) => ({ value: theme.name, label: `Light · ${theme.name}` })),
    ...(!themes.some((theme) => theme.name === env.theme)
      ? [{ value: env.theme, label: `${env.theme} (missing)` }]
      : []),
  ];
  const appearanceOptions = [
    { value: "auto", label: "Auto" },
    { value: "dark", label: "Dark" },
    { value: "light", label: "Light" },
  ];
  const frameOptions = [
    { value: "window", label: "Window" },
    { value: "component", label: "Component" },
  ];
  const localeOptions = [...LOCALES, ...PSEUDO_LOCALES].map((locale) => ({
    value: locale,
    label: `${locale} · ${LOCALE_NAMES[locale]}`,
  }));
  const selectClass = "gallery-control-select";
  return (
    <div className="gallery-controls">
      <Select
        className={selectClass}
        value={env.theme}
        options={themeOptions}
        onChange={(value) => set("theme", value)}
        label="Theme"
      />
      <Select
        className={selectClass}
        value={env.colorScheme}
        options={appearanceOptions}
        onChange={(value) => set("colorScheme", value as GalleryEnv["colorScheme"])}
        label="Appearance"
      />
      <button
        ref={(node) => {
          moreButtonRef.current = node;
          setMoreAnchor(node);
        }}
        type="button"
        className="gallery-more-button"
        aria-haspopup="dialog"
        aria-expanded={moreOpen}
        onClick={() => setMoreOpen((open) => !open)}
      >
        More
      </button>
      <Popover
        open={moreOpen && moreAnchor !== null}
        onOpenChange={setMoreOpen}
        anchor={moreAnchor}
        label="More gallery controls"
        className="gallery-more-popover"
        finalFocus={moreButtonRef}
      >
        <div className="gallery-more-grid">
          <Select
            className={selectClass}
            value={env.locale}
            options={localeOptions}
            onChange={(value) => set("locale", value)}
            label="Locale"
          />
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
          <Select
            className={selectClass}
            value={env.density}
            options={DENSITIES.map((density) => ({ value: density, label: density }))}
            onChange={(value) => set("density", value as GalleryEnv["density"])}
            label="Density"
          />
          <Select
            className={selectClass}
            value={String(env.scale)}
            options={[
              ...(!(SCALES as readonly number[]).includes(env.scale)
                ? [{ value: String(env.scale), label: `${Math.round(env.scale * 100)}%` }]
                : []),
              ...SCALES.map((scale) => ({ value: String(scale), label: `${Math.round(scale * 100)}%` })),
            ]}
            onChange={(value) => set("scale", Number(value))}
            label="Scale"
          />
          <Select
            className={selectClass}
            value={env.frame}
            options={frameOptions}
            onChange={(value) => set("frame", value as GalleryEnv["frame"])}
            label="Frame"
          />
          {env.frame === "window" && (
            <>
              <Select
                className={selectClass}
                value={env.window in WINDOW_PRESETS ? env.window : "custom"}
                options={[
                  ...Object.entries(WINDOW_PRESETS).map(([name, preset]) => ({
                    value: name,
                    label: `${preset.label} (${preset.width}x${preset.height})`,
                  })),
                  { value: "custom", label: "Custom" },
                ]}
                onChange={(value) =>
                  set(
                    "window",
                    value === "custom" ? `${windowSize(env.window).width}x${windowSize(env.window).height}` : value,
                  )
                }
                label="Window"
              />
              {!(env.window in WINDOW_PRESETS) && (
                <label>
                  Custom window
                  <input
                    value={env.window}
                    aria-label="Custom window size"
                    placeholder="1440x900"
                    onChange={(event) =>
                      /^\d{3,4}x\d{3,4}$/.test(event.target.value) && set("window", event.target.value)
                    }
                  />
                </label>
              )}
              <Select
                className={selectClass}
                value={String(env.zoom)}
                options={[
                  ...(!(ZOOMS as readonly (string | number)[]).includes(env.zoom)
                    ? [{ value: String(env.zoom), label: `${Math.round(Number(env.zoom) * 100)}%` }]
                    : []),
                  ...ZOOMS.map((zoom) => ({
                    value: String(zoom),
                    label: zoom === "fit" ? "Fit" : `${Math.round(Number(zoom) * 100)}%`,
                  })),
                ]}
                onChange={(value) => set("zoom", value === "fit" ? "fit" : Number(value))}
                label="Zoom"
              />
              <Select
                className={selectClass}
                value={env.layout}
                options={Object.entries(PANE_LAYOUTS).map(([name, label]) => ({ value: name, label }))}
                onChange={(value) => set("layout", value as PaneLayout)}
                label="Panes"
              />
            </>
          )}
          {env.frame === "component" && (
            <>
              <Select
                className={selectClass}
                value={typeof env.width === "number" ? "custom" : env.width}
                options={[
                  ...Object.entries(WIDTHS).map(([name, px]) => ({ value: name, label: `${name} (${px})` })),
                  { value: "custom", label: "Custom" },
                ]}
                onChange={(value) =>
                  set("width", value === "custom" ? widthPx(env.width) : (value as keyof typeof WIDTHS))
                }
                label="Width"
              />
              {typeof env.width === "number" && (
                <label>
                  Custom width
                  <input
                    type="number"
                    min={240}
                    max={3000}
                    value={env.width}
                    aria-label="Custom width"
                    onChange={(event) => set("width", Number(event.target.value) || 760)}
                  />
                </label>
              )}
            </>
          )}
          <Select
            className={selectClass}
            value={env.dynamicSize}
            options={DYNAMIC_SIZES.map((size) => ({ value: size, label: size }))}
            onChange={(value) => set("dynamicSize", value as GalleryEnv["dynamicSize"])}
            label="Dynamic size"
          />
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
          <button type="button" className="gallery-more-reset" onClick={() => onChange(DEFAULT_ENV)}>
            Reset
          </button>
        </div>
      </Popover>
    </div>
  );
}
