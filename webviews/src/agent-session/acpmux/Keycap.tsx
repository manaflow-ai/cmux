import React from "react";
import { keycapLegend } from "../../ui/keycapLegend";

export { keycapKeys, keycapLegend, keycapStrokes, KEYCAP_THEN } from "../../ui/keycapLegend";

/// The key that runs a control, drawn inside it. Decoration only: the control carries the key in
/// `aria-keyshortcuts`, so its accessible name stays its label. Named keys read as the Mac keyboard
/// prints them (`keycapLegend`): <Keycap>↩</Keycap> draws "return".
export function Keycap({ children }: { children: string }) {
  return (
    <kbd className="acpmux-keycap" aria-hidden="true">
      {keycapLegend(children)}
    </kbd>
  );
}
