import { createContext, useContext, useMemo, useSyncExternalStore } from "react";
import { bundledIconPack, customIconPack, documentIconFamily, subscribeIconFamily } from "./iconPack";
import type { IconAccent, IconPack } from "./types";

export interface IconsValue {
  pack: IconPack;
  accent: IconAccent;
}

export const IconsContext = createContext<IconsValue>({ pack: bundledIconPack, accent: "none" });

/// The page's icon family (`data-icon-family`), live: a pooled page learns it when claimed.
function useDocumentIconFamily(): string | undefined {
  return useSyncExternalStore(subscribeIconFamily, documentIconFamily, () => undefined);
}

/// The pack and accent to draw with. Where the bundled pack applies and the host chose the cmux custom
/// family (Debug Settings `icons.family`), the custom drawings replace it.
export function useIcons(): IconsValue {
  const value = useContext(IconsContext);
  const family = useDocumentIconFamily();
  return useMemo(
    () => (family === "custom" && value.pack === bundledIconPack ? { ...value, pack: customIconPack } : value),
    [value, family],
  );
}
