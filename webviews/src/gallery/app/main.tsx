// The whole app (app.html): one cmux window at its real size, the sidebar, the tab strips and the
// panes laid out from the app's own metrics (window.ts), with the live agent pane in its pane, scaled
// to fit the browser with one transform. Leo, 2026-11-04: "I want the mock web view of the app to be
// legit like 'oh we can see the whole unified piece and it doesn't lag ... my computer/browser when
// I open it'". So this page loads one gallery entry (the app.window scenes) and one stage frame
// (frame.html, `source` pinned to that file), never the shell's registry of every entry; the chrome
// around the pane is static DOM. The choices live in the query, so a link reopens the same window.
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import metrics from "virtual:cmux-gallery/metrics";
import themes from "virtual:cmux-gallery/themes";
import entry from "../scenes/AppWindow.gallery";
import { DEFAULT_ENV, defaultTheme, frameQuery, type Density, type GalleryEnv } from "../env";
import { themeTokens, webThemePayload } from "../theme/web";
import { fitScale, PANE_LAYOUTS, WINDOW_PRESETS, type PaneLayout } from "../window";
import { APP_ENTRY_ID, APP_ENTRY_SOURCE, appWindow, type AppPane, type AppRow } from "./model";
import "../../pages/shared/desktop.css";
import "./app.css";

type Choices = { scene: string; window: string; layout: PaneLayout; scheme: "dark" | "light"; density: Density };

const SCENES = Object.keys(entry.variants);

function readChoices(search: string): Choices {
  const params = new URLSearchParams(search);
  const scene = params.get("scene") ?? "";
  const window = params.get("window") ?? "";
  const layout = params.get("layout") ?? "";
  return {
    scene: SCENES.includes(scene) ? scene : SCENES[0]!,
    window: Object.hasOwn(WINDOW_PRESETS, window) ? window : "pro14",
    layout: Object.hasOwn(PANE_LAYOUTS, layout) ? (layout as PaneLayout) : "agent-right",
    scheme: params.get("scheme") === "light" ? "light" : "dark",
    density: params.get("density") === "compact" ? "compact" : "comfortable",
  };
}

function writeChoices(choices: Choices) {
  const params = new URLSearchParams(choices);
  history.replaceState(null, "", `?${params}`);
}

/** The page's chrome takes the same `--cmux-*` tokens the app hands its web pages. */
function applyTheme(scheme: "dark" | "light") {
  const name = defaultTheme(scheme);
  const theme = themes.find((candidate) => candidate.name === name) ?? themes[0];
  if (!theme) return;
  const { variables, colorScheme } = webThemePayload(themeTokens(theme));
  const root = document.documentElement;
  for (const [key, value] of Object.entries(variables)) root.style.setProperty(key, value);
  root.style.colorScheme = colorScheme;
  root.dataset.scheme = colorScheme;
}

/** The room under the toolbar, followed as the browser resizes. */
function useRoom(ref: React.RefObject<HTMLElement | null>) {
  const [room, setRoom] = useState({ width: 0, height: 0 });
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node) return;
    const measure = () => setRoom({ width: node.clientWidth, height: node.clientHeight });
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    return () => observer.disconnect();
  }, [ref]);
  return room;
}

function Select<T extends string>({
  label,
  value,
  options,
  onChange,
}: {
  label: string;
  value: T;
  options: readonly (readonly [T, string])[];
  onChange: (value: T) => void;
}) {
  return (
    <label className="app-control">
      <span>{label}</span>
      <select aria-label={label} value={value} onChange={(event) => onChange(event.target.value as T)}>
        {options.map(([option, text]) => (
          <option key={option} value={option}>
            {text}
          </option>
        ))}
      </select>
    </label>
  );
}

function Row({ row }: { row: AppRow }) {
  return (
    <li className="app-row" data-active={row.active || undefined} aria-current={row.active || undefined}>
      <span className="app-row-dot" data-indicator={row.indicator ?? "none"} data-unread={row.unread || undefined} />
      <span className="app-row-text">
        <span className="app-row-title">{row.title}</span>
        <span className="app-row-subtitle">{row.folder}</span>
      </span>
    </li>
  );
}

function Pane({ pane, frameSrc, onReady }: { pane: AppPane; frameSrc: string; onReady: () => void }) {
  const ref = useRef<HTMLIFrameElement>(null);
  useEffect(() => {
    if (!pane.hostsEntry) return;
    const receive = (event: MessageEvent) => {
      const data = event.data as { type?: string; status?: string } | undefined;
      if (event.source === ref.current?.contentWindow && data?.type === "cmux-gallery-stage") onReady();
    };
    addEventListener("message", receive);
    return () => removeEventListener("message", receive);
  }, [pane.hostsEntry, onReady]);
  return (
    <section
      className="app-pane"
      data-live={pane.hostsEntry || undefined}
      style={{ left: pane.frame.x, top: pane.frame.y, width: pane.frame.width, height: pane.frame.height }}
    >
      <div className="app-tabstrip" style={{ height: pane.frame.height - pane.content.height }}>
        {pane.tabs.map((tab) => (
          <span key={tab.title} className="app-tab" data-kind={tab.kind} data-active={tab.active || undefined}>
            {tab.title}
          </span>
        ))}
        <span className="app-tab-new" aria-hidden>
          +
        </span>
      </div>
      {pane.hostsEntry ? (
        <iframe
          ref={ref}
          key={frameSrc}
          className="app-stage"
          title="The agent pane"
          src={frameSrc}
          style={{ width: pane.content.width, height: pane.content.height }}
        />
      ) : (
        <div className="app-terminal" style={{ height: pane.content.height }}>
          <span className="app-terminal-prompt">you@mac atlas-web %</span>
          <span className="app-terminal-cursor" />
        </div>
      )}
    </section>
  );
}

function App() {
  const [choices, setChoices] = useState(() => readChoices(location.search));
  const [ready, setReady] = useState(false);
  const roomRef = useRef<HTMLDivElement>(null);
  const room = useRoom(roomRef);
  const set = <K extends keyof Choices>(key: K, value: Choices[K]) => {
    const next = { ...choices, [key]: value };
    writeChoices(next);
    setChoices(next);
  };
  useEffect(() => applyTheme(choices.scheme), [choices.scheme]);
  const variant = entry.variants[choices.scene]!;
  const model = useMemo(
    () => appWindow(variant, { window: choices.window, layout: choices.layout, density: choices.density, metrics }),
    [variant, choices.window, choices.layout, choices.density],
  );
  const env: GalleryEnv = {
    ...DEFAULT_ENV,
    theme: defaultTheme(choices.scheme),
    colorScheme: choices.scheme,
    density: choices.density,
    window: choices.window,
    layout: choices.layout,
  };
  // `entryPath` and `source` both narrow the stage to the one file (registry.ts), so it never
  // starts the other entries' loads.
  const frameSrc = `frame.html?${frameQuery({ entry: APP_ENTRY_ID, variant: choices.scene, source: APP_ENTRY_SOURCE }, env)}&entryPath=${encodeURIComponent(APP_ENTRY_SOURCE)}`;
  useEffect(() => setReady(false), [frameSrc]);
  const scale = room.width ? fitScale(model, { width: room.width - 32, height: room.height - 32 }) : 0;
  const onReady = useMemo(() => () => setReady(true), []);
  return (
    <>
      <header className="app-toolbar">
        <strong>cmux, the whole app</strong>
        <Select
          label="Scene"
          value={choices.scene}
          options={SCENES.map((scene) => [scene, scene.replaceAll("-", " ")] as const)}
          onChange={(value) => set("scene", value)}
        />
        <Select
          label="Window"
          value={choices.window}
          options={Object.entries(WINDOW_PRESETS).map(([name, preset]) => [name, preset.label] as const)}
          onChange={(value) => set("window", value)}
        />
        <Select
          label="Panes"
          value={choices.layout}
          options={Object.entries(PANE_LAYOUTS) as [PaneLayout, string][]}
          onChange={(value) => set("layout", value)}
        />
        <Select
          label="Appearance"
          value={choices.scheme}
          options={[
            ["dark", "Dark"],
            ["light", "Light"],
          ]}
          onChange={(value) => set("scheme", value)}
        />
        <Select
          label="Density"
          value={choices.density}
          options={[
            ["comfortable", "Comfortable"],
            ["compact", "Compact"],
          ]}
          onChange={(value) => set("density", value)}
        />
        <span className="app-note">{variant.note}</span>
        <span className="app-status" aria-live="polite">
          {ready ? `${model.width}×${model.height} · ${Math.round(scale * 100)}%` : "Loading the pane…"}
        </span>
        <a href="./">Gallery</a>
      </header>
      <div className="app-room" ref={roomRef}>
        {scale > 0 && (
          <div className="app-fit" style={{ width: model.width * scale, height: model.height * scale }}>
            <div
              className="app-window"
              data-density={choices.density}
              style={
                {
                  width: model.width,
                  height: model.height,
                  transform: `scale(${scale})`,
                  "--app-radius": `${model.radius}px`,
                  "--app-row-height": `${model.rowHeight}px`,
                  "--app-tab-height": `${model.tabHeight}px`,
                } as React.CSSProperties
              }
            >
              <nav className="app-sidebar" aria-label="Sidebar" style={{ width: model.sidebar.width }}>
                <div className="app-titlebar" style={{ height: model.titlebarHeight }}>
                  <span className="app-light" data-light="close" />
                  <span className="app-light" data-light="minimize" />
                  <span className="app-light" data-light="zoom" />
                </div>
                <div className="app-sidebar-header">Workspaces</div>
                <ul className="app-rows">
                  {model.rows.map((row) => (
                    <Row key={row.id} row={row} />
                  ))}
                </ul>
              </nav>
              {model.panes.map((pane, index) => (
                <Pane key={index} pane={pane} frameSrc={frameSrc} onReady={onReady} />
              ))}
            </div>
          </div>
        )}
      </div>
    </>
  );
}

createRoot(document.getElementById("app")!).render(<App />);
