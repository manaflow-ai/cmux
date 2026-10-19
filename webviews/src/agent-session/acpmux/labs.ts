import { useSyncExternalStore } from "react";

/// Chat features being tried out (Lucas 2026-10-18: generative UI and chat parity), each its own
/// switch. liveRender, renderGuide and renderKit are on by default (Lucas 2026-10-19):
/// - `liveRender`: render pages run on their own, can talk back to the chat (window.cmux), take
///   components, and draw inline as they are written, on the dev server too
///   (conversation/RenderCard.tsx).
/// - `renderKit`: native styles, charts and declarative actions in live render frames.
/// - `renderPreview`: offscreen screenshots and diagnostics for the agent's MCP tool.
/// - `renderExpand`: a hover control opens closed renders in a larger, accessible dialog.
/// - `tableScroll`: constrain wide Markdown cells and let keyboards reach every column.
/// - `renderGuide`: teach agents the inline render fences once per session, with liveRender on.
/// - `contextMeter`: show the context ring beside the model, with its token details.
/// - `promptCollapse`: fold long prompts to eight lines, and open them for Find.
/// - `messageTimes`: show a prompt's send time on hover or focus.
/// - `codeWrap`: remember one wrap choice for every code card in the pane.
/// - `planProgress`: keep the running plan's current step above the composer.
/// - `shortcutsHelp`: show the chat's live keys from its menu.
/// - `chatViewer`: Files and linked files open in one viewer beside the transcript, inside the chat,
///   instead of a new column or a tab over the chat (Lucas 2026-10-19, on by default).
///
/// Set one in the Debug Settings window, for new agent tabs. An explicit boolean in `"labs"` in
/// `agent-pane/layout.json` wins (the app pushes the file live to every chat), then the app's
/// document-start value, then `?data-lab-live-render=off` on the dev server, then the default.
/// Each switch is `data-lab-<kebab-name>="on"` or `"off"` on `<html>`, for CSS.
export const LABS = [
  "liveRender",
  "renderGuide",
  "renderKit",
  "renderPreview",
  "renderExpand",
  "tableScroll",
  "contextMeter",
  "promptCollapse",
  "messageTimes",
  "codeWrap",
  "planProgress",
  "shortcutsHelp",
  "chatViewer",
] as const;
export type Lab = (typeof LABS)[number];
const defaults: Partial<Record<Lab, boolean>> = {
  liveRender: true,
  renderGuide: true,
  renderKit: true,
  renderPreview: true,
  renderExpand: true,
  tableScroll: true,
  chatViewer: true,
};

const attribute = (lab: Lab) => `data-lab-${lab.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`)}`;

// Keep the app's choice before configureLabs writes the same attributes (Lucas 2026-10-18).
const fromApp = new Map<Lab, boolean>();
if (typeof document !== "undefined")
  for (const lab of LABS) {
    const value = document.documentElement.getAttribute(attribute(lab));
    if (value === "on" || value === "off") fromApp.set(lab, value === "on");
  }

let enabled = new Set<Lab>();
const listeners = new Set<() => void>();

/// The host pushed `layout.json`: explicit labs follow live; removed entries return to the page's choices.
export function configureLabs(layout: Record<string, unknown> | undefined): void {
  const labs = layout?.labs;
  const query = new URLSearchParams(typeof location !== "undefined" ? location.search : "");
  const next = new Set<Lab>(
    LABS.filter((lab) => {
      const value = labs && typeof labs === "object" ? (labs as Record<string, unknown>)[lab] : undefined;
      if (typeof value === "boolean") return value;
      const app = fromApp.get(lab);
      if (app !== undefined) return app;
      const override = query.get(attribute(lab));
      if (override === "on" || override === "off") return override === "on";
      return defaults[lab] === true;
    }),
  );
  if (typeof document !== "undefined")
    for (const lab of LABS) {
      const name = attribute(lab);
      const value = next.has(lab) ? "on" : "off";
      if (document.documentElement.getAttribute(name) !== value) document.documentElement.setAttribute(name, value);
    }
  enabled = next;
  for (const listener of listeners) listener();
}

/// Whether `lab` is on now, with the resolved choice also on the page for CSS.
export function labOn(lab: Lab): boolean {
  const value = typeof document !== "undefined" ? document.documentElement.getAttribute(attribute(lab)) : null;
  if (value === "on" || value === "off") return value === "on";
  return enabled.has(lab);
}

configureLabs(undefined);

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

/// Whether `lab` is on, live.
export const useLab = (lab: Lab): boolean =>
  useSyncExternalStore(
    subscribe,
    () => labOn(lab),
    () => labOn(lab),
  );
