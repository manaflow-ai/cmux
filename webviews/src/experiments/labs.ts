// Labs (hq#1980): new looks and behaviors ship behind a flag a person turns on, not in the
// defaults. The flags live in schemas/settings/source/labs.json (owner, dates, cohort, intent);
// the app keeps the names of the ones that are on in `data-labs` on `<html>`, space separated,
// at document start and whenever one changes. Pages read a flag only through these helpers.
// Unlike an experiment (./experiment.ts), a gallery comparison of arms, a Labs flag is a person's
// opt-in in the shipped app. How to add one: skills/cmux-architecture/references/labs-flags.md.
import { useSyncExternalStore } from "react";
import { LABS_FLAGS, type LabsFlagName } from "./labs.generated";

export { LABS_FLAGS, type LabsFlagName };

function onFlags(root: Element): Set<string> {
  return new Set((root.getAttribute("data-labs") ?? "").split(" ").filter(Boolean));
}

/**
 * Whether the Labs flag `name` is on in this page now. Off outside the app (no `data-labs`). A
 * page's first moments can carry the list from when its web view was made (a prewarmed page);
 * the app sets the current one once the page loads, so code that must follow a change uses
 * `useLabsFlag`.
 */
export function labsFlag(name: LabsFlagName, root: Element = document.documentElement): boolean {
  return onFlags(root).has(name);
}

function subscribe(change: () => void): () => void {
  const observer = new MutationObserver(change);
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-labs", "data-labs-team"] });
  return () => observer.disconnect();
}

/** Whether this is a team build (nightly or dev, `data-labs-team`), where pages offer Labs toggles. */
export function labsTeamBuild(root: Element = document.documentElement): boolean {
  return root.getAttribute("data-labs-team") === "1";
}

/** `labsFlag` for a component: it renders again when the flag turns on or off. */
export function useLabsFlag(name: LabsFlagName): boolean {
  return useSyncExternalStore(
    subscribe,
    () => labsFlag(name),
    () => false,
  );
}

/** `labsTeamBuild` for a component: it renders again if the attribute changes. */
export function useLabsTeamBuild(): boolean {
  return useSyncExternalStore(
    subscribe,
    () => labsTeamBuild(),
    () => false,
  );
}
