import { useSyncExternalStore } from "react";

/// Chat features being tried out (Lucas 2026-10-18: generative UI and chat parity), each its own
/// switch. Only liveRender is on by default (Lucas 2026-10-18):
/// - `liveRender`: render pages run on their own, can talk back to the chat (window.cmux), take
///   components, and draw inline as they are written, on the dev server too
///   (conversation/RenderCard.tsx).
/// - `contextMeter`: show the context ring beside the model, with its token details.
/// - `promptCollapse`: fold long prompts to eight lines, and open them for Find.
/// - `messageTimes`: show a prompt's send time on hover or focus.
/// - `codeWrap`: remember one wrap choice for every code card in the pane.
/// - `planProgress`: keep the running plan's current step above the composer.
/// - `shortcutsHelp`: show the chat's live keys from its menu.
///
/// Set one with `"labs": {"liveRender": false}` in `agent-pane/layout.json` (the App pushes the
/// file to every chat), or in the dev server with `?data-lab-live-render=off`. Each enabled switch is
/// `data-lab-<name>="on"` on `<html>`, for CSS.
export const LABS = [
  "liveRender",
  "contextMeter",
  "promptCollapse",
  "messageTimes",
  "codeWrap",
  "planProgress",
  "shortcutsHelp",
] as const;
export type Lab = (typeof LABS)[number];
const defaults: Partial<Record<Lab, boolean>> = { liveRender: true };

const attribute = (lab: Lab) => `data-lab-${lab.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`)}`;

let fromLayout = new Set<Lab>();
const listeners = new Set<() => void>();

/// The host pushed `layout.json` (or `{}` when it was removed): every lab follows at once.
export function configureLabs(layout: Record<string, unknown> | undefined): void {
  const labs = layout?.labs;
  const next = new Set<Lab>(
    LABS.filter((lab) => {
      const value = labs && typeof labs === "object" ? (labs as Record<string, unknown>)[lab] : undefined;
      return typeof value === "boolean" ? value : defaults[lab] === true;
    }),
  );
  if (typeof document !== "undefined")
    for (const lab of LABS) {
      // A dev URL can override the default too (Lucas 2026-10-18).
      const override =
        typeof location !== "undefined" ? new URLSearchParams(location.search).get(attribute(lab)) : null;
      if (override === "on" || override === "off") document.documentElement.setAttribute(attribute(lab), override);
      else if (next.has(lab)) document.documentElement.setAttribute(attribute(lab), "on");
      else if (defaults[lab]) document.documentElement.setAttribute(attribute(lab), "off");
      else if (fromLayout.has(lab)) document.documentElement.removeAttribute(attribute(lab));
    }
  fromLayout = next;
  for (const listener of listeners) listener();
}

/// Whether `lab` is on now: layout.json's, else the page's `data-lab-<name>`.
export function labOn(lab: Lab): boolean {
  const value = typeof document !== "undefined" ? document.documentElement.getAttribute(attribute(lab)) : null;
  if (value === "on" || value === "off") return value === "on";
  return fromLayout.has(lab) || defaults[lab] === true;
}

if (typeof document !== "undefined")
  for (const lab of LABS)
    if (defaults[lab] && !document.documentElement.hasAttribute(attribute(lab)))
      document.documentElement.setAttribute(attribute(lab), "on");

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
