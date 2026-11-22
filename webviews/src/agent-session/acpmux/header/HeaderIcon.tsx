import { useEffect, useSyncExternalStore } from "react";
import { harnessSymbolsSnapshot, loadHarnessSymbol, subscribeHarnessIcons } from "../../shared/harnessIcons";
import { Icon } from "../icons/Icon";

// Use the host's SF Symbol templates, as the native toolbar does. The bundled glyph keeps its
// footprint while the template loads and in a browser gallery without a macOS symbol host.
import { HEADER_SYMBOLS, PACK_DRAWN_SYMBOLS } from "./headerSymbols";

export function HeaderIcon({ name, size = 16, lit = false }: { name: string; size?: number; lit?: boolean }) {
  const symbols = useSyncExternalStore(subscribeHarnessIcons, harnessSymbolsSnapshot, harnessSymbolsSnapshot);
  const mapped = HEADER_SYMBOLS[name];
  const symbol = mapped && !PACK_DRAWN_SYMBOLS.has(mapped) ? mapped : undefined;
  useEffect(() => {
    if (symbol) loadHarnessSymbol(symbol);
  }, [symbol]);
  const src = symbol ? symbols.get(symbol) : undefined;
  // On is the lit ink (and header.css's square), never the pack's heavier Solid form: the glyph keeps
  // its weight when its panel opens, as the native row's does (Leo 2026-11-06: "the symbol itself is
  // getting bolded for some reason").
  const color = lit ? "var(--agent-lit-glyph, var(--agent-accent))" : undefined;
  // Both paths carry acpmux-header-glyph: header.css sizes it from the icon box token, so the glyph
  // grows with the interface size like the square around it (Leo 2026-11-04: "so all those things
  // are proportional"). `size` stays the svg's attribute size where that sheet is not loaded.
  if (!src) return <Icon name={name} size={size} color={color} className="acpmux-header-glyph" />;
  const mask = `url("${src}") center / contain no-repeat`;
  return (
    <span
      className="acpmux-header-symbol acpmux-header-glyph"
      data-icon={name}
      data-symbol={symbol}
      aria-hidden="true"
      style={{
        color,
        mask,
        WebkitMask: mask,
      }}
    />
  );
}
