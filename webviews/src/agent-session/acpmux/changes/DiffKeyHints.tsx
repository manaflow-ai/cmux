import React from "react";
import { Keycap } from "../Keycap";
import { useT } from "../i18n";

/// The changes view's reading keys, always in view (useDiffKeys). They are the view's own keys,
/// not app shortcuts the user rebinds, so they are drawn as they are. `hunkKey` is s in Unstaged,
/// u in Staged.
export function DiffKeyHints({ hunkKey }: { hunkKey?: "s" | "u" }) {
  const t = useT();
  const hints: [keys: string[], label: string][] = [
    [["j", "k"], t("diff.keys.files")],
    [["n", "p"], t("diff.keys.changes")],
    [["v"], t("diff.keys.viewed")],
    ...(hunkKey
      ? [[[hunkKey], t(hunkKey === "s" ? "diff.keys.stageHunk" : "diff.keys.unstageHunk")] as [string[], string]]
      : []),
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
