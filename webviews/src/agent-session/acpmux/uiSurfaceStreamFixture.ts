// l10n-allow-file: measurement fixture (a golden agent UI surface), not shipped UI.
// The one agent UI surface stream both frame measurements play (plans/cmux-next/agent-ui-surfaces-DESIGN.md,
// "Streaming and frames"): the headless bench (webviews/bench/ui-surface-stream-frames.bench.ts) sends it as a
// tool call's `_meta.acpmux.uiSurface`, and the live pane's DEBUG `debug.agent_pane` `stream` with `surface`
// (surfaceStreamDebug.ts, golden.py `ui_surface_stream`) puts it on a tool row. Both read Rust's golden
// `cmux-catalog-cards` (approval, review, progress, table, charts, field, button) as cmux-ui-surfaces emits it.
// A copy of cmux-tui/crates/cmux-ui-surfaces/tests/golden/cmux-catalog-cards.json (see uiSurface/golden/golden.test.ts).
import cmuxCatalogCards from "./uiSurface/golden/cmux-catalog-cards.json";

/// The golden the stream grows (the `surface` name `debug.agent_pane stream` takes).
export const UI_SURFACE_STREAM_FIXTURE = "cmux-catalog-cards";
/// Updates per stream and their rate, as the design's measurement names them.
export const UI_SURFACE_STREAM_UPDATES = 40;
export const UI_SURFACE_STREAM_HZ = 60;
/// The streamed tool call.
export const UI_SURFACE_STREAM_CALL = "ui-surface-call";
export const UI_SURFACE_STREAM_TITLE = "cmux · ui_surface";

type GoldenNode = Record<string, unknown> & { id?: unknown };
const golden = (cmuxCatalogCards as unknown as { surfaces: Record<string, unknown>[] }).surfaces[0]!;
const goldenRoot = golden.root as GoldenNode & { children: GoldenNode[] };

/// The surface after update `index` (0-based) of `updates`, raw as Rust emits it (the whole normalized tree on
/// every update, never a diff): one more of the golden's nodes every few updates, all of them on the last; the
/// `build` progress moves on every update and is done on the last; `streaming` until the last, then `ready`.
export function uiSurfaceStreamAt(index: number, updates = UI_SURFACE_STREAM_UPDATES): Record<string, unknown> {
  const children = goldenRoot.children;
  const last = index >= updates - 1;
  const count = Math.min(children.length, 1 + Math.floor(((index + 1) * children.length) / updates));
  const value = Math.round(((index + 1) / updates) * 100);
  const shown = children
    .slice(0, count)
    .map((node) => (node.id === "build" ? { ...node, value, state: last ? "done" : "running" } : node));
  return { ...golden, status: last ? "ready" : "streaming", root: { ...goldenRoot, children: shown } };
}
