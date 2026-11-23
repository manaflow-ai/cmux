import { useMemo, type ReactNode } from "react";
import { bundledIconPack } from "./iconPack";
import type { IconAccent, IconPack } from "./types";
import { IconsContext } from "./iconsContextModel";
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
