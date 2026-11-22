// l10n-allow-file: gallery fixture text, not shipped UI.
// The auto gallery (RFD 0009 part 5): every widget at each size class it declares, in a light and a
// dark panel side by side, with long text, empty and error states, on one page. The states are
// fixtures/widget-previews.json, which `cmux ext preview` writes (cmux-tui/src/cli/ext/preview.rs):
// each widget's own preview/scenes.json states ({name: {size, ops}}, the first-party widgets'
// shape), plus the long-text, empty and error states it derives where the widget recorded none,
// each with its design check findings. This entry only draws them, through the real renderer.
//   cmux ext preview examples/extensions --out webviews/src/apps/scene/fixtures/widget-previews.json
// (a cmux-tui test fails when the file is stale).
import { useState, type CSSProperties } from "react";
import { agentThemeVariables } from "../../agent-session/shared/theme";
import { componentEntry } from "../../gallery/format";
import { agentPaneTheme, themeTokens } from "../../gallery/theme/web";
import { SHEET_THEMES, themedPanelStyle } from "../../ui/TokenSheet";
import previews from "./fixtures/widget-previews.json";
import { SceneFailure } from "./SceneFailure";
import { SceneRenderer } from "./SceneRenderer";
import { SceneStore, type SceneOp } from "./store";

type Scheme = "light" | "dark";
type Finding = { check: string; count: number; message: string };
type State = {
  name: string;
  size: string;
  kind: "recorded" | "long-text" | "empty" | "error";
  from?: string;
  failed?: string;
  ops?: SceneOp[];
  warnings: Finding[];
};
type Missing = { size: string; kind: string; fix: string };
type Widget = { dir: string; id: string; name: string; sizes: string[]; states: State[]; missing: Missing[] };
type Props = { widget?: string; kinds?: State["kind"][] };

const WIDGETS = (previews as unknown as { widgets: Widget[] }).widgets;

/** Apple's widget sizes in points: small is one tile, medium two side by side, large two by two. */
const TILE: Record<string, { width: number; height: number }> = {
  small: { width: 170, height: 170 },
  medium: { width: 364, height: 170 },
  large: { width: 364, height: 382 },
};

/** A panel themed light or dark on its own: the page tokens and the pane's agent variables. */
function schemeStyle(scheme: Scheme): CSSProperties {
  const theme = SHEET_THEMES[scheme];
  const agent = agentPaneTheme(themeTokens(theme), false);
  const vars: Record<string, string> = {};
  for (const [key, variable] of Object.entries(agentThemeVariables)) {
    const value = agent[key];
    if (variable && (typeof value === "string" || typeof value === "number")) vars[variable] = String(value);
  }
  return { ...themedPanelStyle(theme), ...vars, color: "var(--agent-text)" } as CSSProperties;
}

const SCHEMES: Record<Scheme, CSSProperties> = { light: schemeStyle("light"), dark: schemeStyle("dark") };

// The New Tab card grows the scene root to the tile; do the same here.
const TILE_CSS = `.widget-preview-tile > .cmux-app-scene-root { flex: 1 1 auto; display: flex; width: 100%; min-height: 0 }
.widget-preview-tile > .cmux-app-scene-root > [data-app-node],
.widget-preview-tile > .cmux-app-scene-root > .cmux-app-scene-context > [data-app-node] { flex: 1 1 auto; width: 100% }`;

function Tile({ state }: { state: State }) {
  const [store] = useState(() => {
    const s = new SceneStore();
    if (state.ops) s.apply(state.ops, true);
    return s;
  });
  const size = TILE[state.size] ?? TILE.small;
  return (
    <div
      className="widget-preview-tile"
      data-widget-preview-tile={state.name}
      style={{
        ...size,
        flexShrink: 0,
        display: "flex",
        overflow: "hidden",
        borderRadius: 16,
        background: "var(--agent-surface-elevated)",
        border: "1px solid var(--agent-border)",
      }}
    >
      {state.failed ? (
        <SceneFailure status={{ state: "failed", reason: state.failed }} />
      ) : (
        <SceneRenderer store={store} dispatch={() => {}} />
      )}
    </div>
  );
}

function Caption({ state }: { state: State }) {
  const derived = state.from ? `derived from ${state.from}` : "recorded";
  const count = state.warnings.length;
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 2, maxWidth: TILE[state.size]?.width ?? 170 }}>
      <div>
        <strong>{state.name}</strong> <span style={{ color: "var(--agent-muted)" }}>{derived}</span>
      </div>
      <div
        title={state.warnings.map((w) => `${w.check}: ${w.message}`).join("\n")}
        style={{ color: count ? "var(--agent-warning)" : "var(--agent-muted)" }}
      >
        {count === 0
          ? "No design warnings"
          : `${count === 1 ? "1 warning" : `${count} warnings`}: ${state.warnings.map((w) => w.check).join(", ")}`}
      </div>
    </div>
  );
}

function SizeRow({ widget, size, kinds }: { widget: Widget; size: string; kinds?: State["kind"][] }) {
  const states = widget.states.filter((s) => s.size === size && (!kinds || kinds.includes(s.kind)));
  const missing = widget.missing.filter((m) => m.size === size);
  return (
    <section data-widget-preview-size={size} style={{ display: "flex", flexDirection: "column", gap: 8 }}>
      <div style={{ color: "var(--agent-muted)" }}>{size}</div>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 16, alignItems: "flex-start" }}>
        {states.map((state) => (
          <div key={state.name} style={{ display: "flex", flexDirection: "column", gap: 6 }}>
            <Caption state={state} />
            <div style={{ display: "flex", gap: 8 }}>
              {(["light", "dark"] as const).map((scheme) => (
                <div
                  key={scheme}
                  data-scheme={scheme}
                  aria-label={scheme === "light" ? "Light" : "Dark"}
                  style={{ ...SCHEMES[scheme], padding: 8, borderRadius: 20 }}
                >
                  <Tile state={state} />
                </div>
              ))}
            </div>
          </div>
        ))}
      </div>
      {missing.map((m) => (
        <div key={`${m.size}.${m.kind}`} style={{ color: "var(--agent-muted)" }}>
          No {m.kind} state: {m.fix}
        </div>
      ))}
    </section>
  );
}

function WidgetPreviews({ widget, kinds }: Props) {
  const shown = widget ? WIDGETS.filter((w) => w.id === widget) : WIDGETS;
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 24, padding: 12, fontSize: "var(--text-detail)" }}>
      <style>{TILE_CSS}</style>
      {shown.map((w) => (
        <article key={w.id} data-widget-preview={w.id} style={{ display: "flex", flexDirection: "column", gap: 12 }}>
          <div>
            <strong>{w.name}</strong> <span style={{ color: "var(--agent-muted)" }}>{w.dir}</span>
          </div>
          {w.sizes.map((size) => (
            <SizeRow key={size} widget={w} size={size} kinds={kinds} />
          ))}
        </article>
      ))}
    </div>
  );
}

const variants: Record<string, { note: string; props: Props }> = {
  all: {
    note: "Every widget, every declared size, every state, light and dark: the page a person or an agent checks before a widget ships.",
    props: {},
  },
  "all-stress": {
    note: "Only the long-text, empty and error states of every widget: where a layout breaks first.",
    props: { kinds: ["long-text", "empty", "error"] },
  },
};
for (const w of WIDGETS) {
  const recorded = w.states.filter((s) => s.kind === "recorded").length;
  variants[w.id.replace(/[^a-z0-9]+/gi, "-")] = {
    note: `${w.name} (${w.dir}): ${recorded} recorded states and the derived ones, at ${w.sizes.join(", ")}.`,
    props: { widget: w.id },
  };
}

export default componentEntry<Props>({
  id: "apps.widget-previews",
  title: "Auto gallery: every widget per size, light and dark, long text, empty and error",
  area: "Apps",
  pane: true,
  height: 1600,
  widths: { narrow: 1200, normal: 1200 },
  keywords: [
    "auto gallery",
    "widget previews",
    "preview/scenes.json",
    "ext preview",
    "long text",
    "empty state",
    "error state",
    "light and dark",
    "bad design proof",
  ],
  covers: ["apps/scene/SceneRenderer.tsx", "apps/scene/SceneFailure.tsx"],
  load: async () => WidgetPreviews,
  variants,
});
