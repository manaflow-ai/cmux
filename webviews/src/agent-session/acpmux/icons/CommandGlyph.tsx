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

export function CommandGlyph({ symbol = "command" }: { symbol?: string }) {
  const symbols = useSyncExternalStore(subscribeHarnessIcons, harnessSymbolsSnapshot, harnessSymbolsSnapshot);
  const revision = useSyncExternalStore(subscribeHarnessIcons, harnessSymbolHostSnapshot, harnessSymbolHostSnapshot);
  const override = overrides.get(symbol);
  useEffect(() => {
    if (!override) loadHarnessSymbol(symbol);
  }, [symbol, override, revision]);
  const src = symbols.get(symbol);
  if (!override && src)
    return <span className="nt-command-symbol" data-symbol={symbol} style={{ maskImage: `url("${src}")` }} />;
  return <Icon name={override ?? aliases.get(symbol) ?? "composer.command"} size={14} />;
}
