import { useEffect, useSyncExternalStore } from "react";
import { harnessSymbolsSnapshot, loadHarnessSymbol, subscribeHarnessIcons } from "../../shared/harnessIcons";
import { Icon } from "../icons/Icon";

// Use the host's SF Symbol templates, as the native toolbar does. The bundled glyph keeps its
// footprint while the template loads and in a browser gallery without a macOS symbol host.
import { HEADER_SYMBOLS } from "./headerSymbols";

export function HeaderIcon({ name, size = 16, selected = false }: { name: string; size?: number; selected?: boolean }) {
  const symbols = useSyncExternalStore(subscribeHarnessIcons, harnessSymbolsSnapshot, harnessSymbolsSnapshot);
  const symbol = HEADER_SYMBOLS[name];
  useEffect(() => {
    if (symbol) loadHarnessSymbol(symbol);
  }, [symbol]);
  const src = symbol ? symbols.get(symbol) : undefined;
  const color = selected ? "var(--agent-lit-glyph, var(--agent-accent))" : undefined;
  if (!src) return <Icon name={name} size={size} selected={selected} color={color} />;
  const mask = `url("${src}") center / contain no-repeat`;
  return (
    <span
      className="acpmux-header-symbol"
      data-icon={name}
      data-symbol={symbol}
      aria-hidden="true"
      style={{
        width: size,
        height: size,
        color,
        mask,
        WebkitMask: mask,
        rotate: name === "action.more.vertical" ? "90deg" : undefined,
      }}
    />
  );
}
