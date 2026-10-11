import React from "react";
import { Keycap } from "./Keycap";
import { useT } from "./i18n";

/// Start Agent's keys, always in view: Return starts the chat in the background, ⌘Return starts it
/// and opens it in a window, Escape hides the panel. The keys are the composer's own (Composer, useEscapeToDismiss), not
/// app shortcuts the user rebinds, so they are drawn as they are.
export function QuickKeyHints() {
  const t = useT();
  const hints: [key: string, label: string][] = [
    ["↩", t("quick.start")],
    ["⌘↩", t("quick.startAndOpen")],
    ["esc", t("quick.close")],
  ];
  return (
    <footer className="acpmux-quick-keys" aria-label={t("quick.keys")}>
      {hints.map(([key, label], index) => (
        <React.Fragment key={key}>
          {index > 0 && (
            <span className="acpmux-quick-keys-dot" aria-hidden="true">
              ·
            </span>
          )}
          <span className="acpmux-quick-key">
            <Keycap>{key}</Keycap>
            {label}
          </span>
        </React.Fragment>
      ))}
    </footer>
  );
}
