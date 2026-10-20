import { useSyncExternalStore } from "react";

/// Files and linked files share one viewer beside the transcript. An explicit layout choice
/// takes precedence over the app's document-start value, then the dev query and default.
export const LABS = ["chatViewer"] as const;
export type Lab = (typeof LABS)[number];
const defaults: Record<Lab, boolean> = { chatViewer: true };

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
