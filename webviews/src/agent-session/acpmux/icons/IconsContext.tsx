import { createContext, useContext, useMemo, useSyncExternalStore, type ReactNode } from "react";
import { bundledIconPack, customIconPack, documentIconFamily, subscribeIconFamily } from "./iconPack";
import type { IconAccent, IconPack } from "./types";

export interface IconsValue {
  pack: IconPack;
  accent: IconAccent;
}

const IconsContext = createContext<IconsValue>({ pack: bundledIconPack, accent: "none" });

/// The pack and accent every Icon below draws with. Without a provider icons use the bundled pack.
export function IconsProvider({
  pack = bundledIconPack,
  accent = "none",
  children,
}: {
  pack?: IconPack;
  accent?: IconAccent;
  children: ReactNode;
}) {
  const value = useMemo(() => ({ pack, accent }), [pack, accent]);
  return <IconsContext.Provider value={value}>{children}</IconsContext.Provider>;
}

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
