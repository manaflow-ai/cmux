import React from "react";
import { Keycap } from "../Keycap";
import { useT } from "../i18n";

/// The changes view's reading keys, always in view (useDiffKeys). They are the view's own keys,
/// not app shortcuts the user rebinds, so they are drawn as they are.
export function DiffKeyHints() {
  const t = useT();
  const hints: [keys: string[], label: string][] = [
    [["j", "k"], t("diff.keys.files")],
    [["n", "p"], t("diff.keys.changes")],
    [["esc"], t("diff.keys.back")],
  ];
  return (
    <footer className="acpmux-diff-keys" aria-label={t("diff.keys")}>
      {hints.map(([keys, label], index) => (
        <React.Fragment key={label}>
          {index > 0 && (
            <span className="acpmux-diff-keys-dot" aria-hidden="true">
              ·
            </span>
          )}
          <span className="acpmux-diff-key">
            {keys.map((key) => (
              <Keycap key={key}>{key}</Keycap>
            ))}
            {label}
          </span>
        </React.Fragment>
      ))}
    </footer>
  );
}
