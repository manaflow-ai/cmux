// An opened edit's lines on @pierre/diffs: the body of an EditDiff card. EditDiff.tsx loads it after
// the page's first frame, so the page's first script parses without Pierre (bd cx-z9kz0).
import { useEffect, useMemo, useState } from "react";
import { getFiletypeFromFileName, getSingularPatch, setLanguageOverride } from "@pierre/diffs";
import { FileDiff, WorkerPoolContext } from "@pierre/diffs/react";
import type { TurnFile } from "../diff";
import { AGENT_DIFF_THEME, AGENT_DIFF_THEME_LIGHT, diffUnsafeCSS, registerAgentDiffTheme } from "../diffTheme";
import { isHighlighted } from "../shikiLanguages";
import { useT } from "../i18n";
import { paneHighlightPool } from "./highlightPool";
import { PIERRE_BLOCK_CSS } from "./sideways";

/// The pane's theme (applyAgentTheme) is light or dark; syntax colors follow it.
const paneThemeType = () =>
  document.documentElement.dataset.theme === "light" ? ("light" as const) : ("dark" as const);

/// Pierre paints its host in the page color; here it is clear, so the card's fill and ring show
/// around the lines. Changed lines keep their tints, which mix with transparent.
const cardUnsafeCSS = `${diffUnsafeCSS}
:host {
  --diffs-dark-bg: transparent;
  --diffs-light-bg: transparent;
  --diffs-font-size: var(--cv-codeblock-size, var(--cmux-diff-font-size, var(--text-detail)));
  --diffs-line-height: var(--cv-codeblock-line-height, var(--cmux-diff-line-height, 18px));
  --diffs-font-family: var(--cv-mono);
  background: transparent;
}
${PIERRE_BLOCK_CSS}`;

/// Pierre's options for an edit placed in its file (numbered) and for a bare fragment; `wrap` wraps
/// long lines (a hanging indent, `PIERRE_BLOCK_CSS`) instead of scrolling them sideways.
function diffOptions(numbered: boolean, themeType: "light" | "dark", wrap: boolean) {
  return {
    theme: { dark: AGENT_DIFF_THEME, light: AGENT_DIFF_THEME_LIGHT },
    themeType,
    diffStyle: "unified" as const,
    diffIndicators: "bars" as const,
    hunkSeparators: "line-info" as const,
    lineDiffType: "none" as const,
    overflow: wrap ? ("wrap" as const) : ("scroll" as const),
    // A fragment edit has no known place in its file, so its numbers would be made up.
    disableLineNumbers: !numbered,
    // The bundled page allows no WebAssembly.
    preferredHighlighter: "shiki-js" as const,
    disableFileHeader: true,
    unsafeCSS: cardUnsafeCSS,
  };
}

/// `patches` are the file's edits as patch text (`editPatch`), one per edit; `wrap` is the block's
/// Wrap lines (blockWrap.ts).
export function EditDiffHunks({ file, patches, wrap }: { file: TurnFile; patches: string[]; wrap: boolean }) {
  const t = useT();
  registerAgentDiffTheme();
  // The pane's theme can switch while the card is open; syntax colors follow it.
  const [themeType, setThemeType] = useState(paneThemeType);
  useEffect(() => {
    const theme = new MutationObserver(() => setThemeType(paneThemeType()));
    theme.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    return () => theme.disconnect();
  }, []);
  const options = useMemo(
    () => ({ numbered: diffOptions(true, themeType, wrap), fragment: diffOptions(false, themeType, wrap) }),
    [themeType, wrap],
  );
  // A tool call's update (its status, say) rebuilds the file; compared by text, an unchanged
  // edit keeps its parsed diff and does not paint again.
  const patchText = patches.join("\0");
  const highlighted = isHighlighted(getFiletypeFromFileName(file.displayPath));
  const language = highlighted ? getFiletypeFromFileName(file.displayPath) : "text";
  const workerPool = paneHighlightPool("none", language);
  const diffs = useMemo(
    () =>
      patchText.split("\0").map((patch) => {
        const parsed = getSingularPatch(patch);
        return highlighted ? parsed : setLanguageOverride(parsed, "text");
      }),
    [patchText, highlighted],
  );
  return file.edits.map((edit, index) =>
    edit.hunks.length ? (
      <WorkerPoolContext.Provider key={edit.toolId + index} value={workerPool}>
        <FileDiff fileDiff={diffs[index]!} options={edit.numbered ? options.numbered : options.fragment} />
      </WorkerPoolContext.Provider>
    ) : (
      <div key={edit.toolId + index} className="cv-edit-diff__empty">
        {t("changes.noLineChanges")}
      </div>
    ),
  );
}
