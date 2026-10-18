import { useEffect, useState } from "react";
import type { GhosttyTheme } from "./ghostty";
import { loadGalleryThemes } from "./catalog";

let cached: GhosttyTheme[] | undefined;
let pending: Promise<GhosttyTheme[]> | undefined;

export function useGalleryThemes(): GhosttyTheme[] {
  const [themes, setThemes] = useState<GhosttyTheme[]>(cached ?? []);
  useEffect(() => {
    if (!pending) pending = loadGalleryThemes().then((value) => (cached = value));
    void pending.then(setThemes);
  }, []);
  return themes;
}
