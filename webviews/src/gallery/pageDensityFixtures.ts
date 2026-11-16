// l10n-allow-file: gallery diagnostics, not shipped UI.
import type { Play } from "./play";

export const pageDensities = [
  { name: "ultra-compact", scale: 24 / 30 },
  { name: "compact", scale: 28 / 30 },
  { name: "default", scale: 1 },
  { name: "comfortable", scale: 32 / 30 },
  { name: "spacious", scale: 36 / 30 },
] as const;

export function pageDensityPlay(scale: number): Play {
  return async ({ document }) => {
    const root = document.documentElement;
    root.style.setProperty("--cmux-density-scale", String(scale));
    root.style.setProperty("--cmux-density-text-scale", String(scale));
    root.style.setProperty("--cmux-row-icon-scale", String(scale));
    root.style.setProperty("--cmux-sidebar-row-height", `${30 * scale}px`);
    root.style.setProperty("--cmux-sidebar-row-font-size", `${14 * scale}px`);
    root.style.setProperty("--cmux-sidebar-row-radius", `${8 * scale}px`);
    root.style.setProperty("--cmux-sidebar-row-inset", `${8 * scale}px`);
    root.style.setProperty("--cmux-sidebar-row-gap", `${2 * scale}px`);
  };
}
