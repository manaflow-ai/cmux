import { useEffect, useSyncExternalStore } from "react";
import catalog from "./iconCatalog.json";
import {
  harnessSymbolHostSnapshot,
  harnessSymbolsSnapshot,
  loadHarnessSymbol,
  subscribeHarnessIcons,
} from "../../shared/harnessIcons";
import { Icon } from "./Icon";

// Use the native catalog for gallery fallbacks and the same overrides as the palette.
const overrides = new Map(
  catalog.icons.flatMap((entry) => (entry.overrides ?? []).map((symbol) => [symbol, entry.name] as const)),
);
const aliases = new Map<string, string>();
for (const entry of catalog.icons) {
  if (!("alias" in entry && entry.alias === false) && !aliases.has(entry.sf)) aliases.set(entry.sf, entry.name);
}

/// An action's SF Symbol as a row icon. A symbol the cmux pack draws (an override or the pack icon
/// for that symbol) is the pack's own SVG, the same art and padding as the rows' other icons; the
/// host's image of it (drawn edge to edge) read bigger beside them (Lucas 2026-11-18: two search
/// icons, two sizes). Only a symbol the pack lacks asks the host for its image.
export function CommandGlyph({ symbol = "command" }: { symbol?: string }) {
  const symbols = useSyncExternalStore(subscribeHarnessIcons, harnessSymbolsSnapshot, harnessSymbolsSnapshot);
  const revision = useSyncExternalStore(subscribeHarnessIcons, harnessSymbolHostSnapshot, harnessSymbolHostSnapshot);
  const pack = overrides.get(symbol) ?? aliases.get(symbol);
  useEffect(() => {
    if (!pack) loadHarnessSymbol(symbol);
  }, [symbol, pack, revision]);
  const src = symbols.get(symbol);
  if (!pack && src)
    return <span className="nt-command-symbol" data-symbol={symbol} style={{ maskImage: `url("${src}")` }} />;
  return <Icon name={pack ?? "composer.command"} size={14} />;
}
