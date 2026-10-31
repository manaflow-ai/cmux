import type { CSSProperties } from "react";
import type { TurnFile } from "../diff";
import { useT } from "../i18n";

/** No syntax renderer in this dependency graph. One painted block per edit, even for huge diffs.
 * The card's existing preview cap and fade also apply while its chunk is pending. Expanded
 * wrapped lines and skipped-line separators acquire their exact height when Pierre loads. */
export function EditDiffLoading({ file }: { file: TurnFile }) {
  const t = useT();
  return (
    <section className="cv-edit-diff__loading" aria-label={t("changes.loading")} aria-busy="true">
      {file.edits.map((edit, index) => {
        const lines = edit.hunks.reduce((sum, hunk) => sum + hunk.lines.length, 0);
        return lines ? (
          <div
            key={edit.toolId + index}
            className="cv-edit-diff__loading-lines"
            data-numbered={edit.numbered}
            aria-hidden="true"
            style={{ "--cv-loading-lines": lines } as CSSProperties}
          />
        ) : (
          <div key={edit.toolId + index} className="cv-edit-diff__empty">
            {t("changes.noLineChanges")}
          </div>
        );
      })}
    </section>
  );
}
