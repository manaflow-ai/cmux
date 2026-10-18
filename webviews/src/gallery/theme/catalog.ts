import type { GhosttyTheme } from "./ghostty";

/** Loads the shipped theme catalog without asking Vite to parse a 1.2 MB JavaScript module. */
export async function loadGalleryThemes(): Promise<GhosttyTheme[]> {
  const response = await fetch(new URL("__cmux_gallery/themes.json", document.baseURI));
  if (!response.ok) throw new Error(`Gallery theme catalog failed: ${response.status}`);
  const themes: unknown = await response.json();
  if (!Array.isArray(themes)) throw new Error("Gallery theme catalog is not an array");
  return themes as GhosttyTheme[];
}
