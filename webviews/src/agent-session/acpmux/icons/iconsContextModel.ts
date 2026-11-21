import { createContext, useContext, useMemo, useSyncExternalStore } from "react";
import { bundledIconPack, documentIconFamily, familyIconPack, subscribeIconFamily } from "./iconPack";
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

/// The pack and accent to draw with. Where the bundled pack applies and the host chose a family (cmux custom
/// or Neko, `data-icon-family`), that family's drawings replace it.
export function useIcons(): IconsValue {
  const value = useContext(IconsContext);
  const family = useDocumentIconFamily();
  return useMemo(() => {
    const pack = familyIconPack(value.pack, family);
    return pack === value.pack ? value : { ...value, pack };
  }, [value, family]);
}
