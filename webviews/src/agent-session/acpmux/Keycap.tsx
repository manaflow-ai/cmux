import React from "react";

/// The key that runs a control, drawn inside it. Decoration only: the control carries the key in
/// `aria-keyshortcuts`, so its accessible name stays its label.
export function Keycap({ children }: { children: string }) {
  return (
    <kbd className="acpmux-keycap" aria-hidden="true">
      {children}
    </kbd>
  );
}
