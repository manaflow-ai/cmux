// An opened edit inside the transcript: a card per changed file with its
// name, the lines added and removed, copy, and the change on @pierre/diffs, scrolling past a
// few lines. The changes view (changes/EditBlock.tsx) draws the same edits at full size.
import { useEffect, useMemo, useState } from "react";
import { getFiletypeFromFileName, getSingularPatch, setLanguageOverride } from "@pierre/diffs";
import { FileDiff } from "@pierre/diffs/react";
import { editPatch, type TurnFile } from "../diff";
import { AGENT_DIFF_THEME, AGENT_DIFF_THEME_LIGHT, diffUnsafeCSS, registerAgentDiffTheme } from "../diffTheme";
import { isHighlighted } from "../shikiLanguages";
import { copyText } from "./clipboard";
import { Copy } from "./icons";
import { useT } from "../i18n";

/// The pane's theme (applyAgentTheme) is light or dark; syntax colors follow it.
const paneThemeType = () =>
  document.documentElement.dataset.theme === "light" ? ("light" as const) : ("dark" as const);

/// Pierre paints its host in the page color; here it is clear, so the card's fill and ring show
/// around the lines. Changed lines keep their tints, which mix with transparent.
const cardUnsafeCSS = `${diffUnsafeCSS}
:host { --diffs-dark-bg: transparent; --diffs-light-bg: transparent; background: transparent; }
`;

/// Pierre's options for an edit placed in its file (numbered) and for a bare fragment.
function diffOptions(numbered: boolean, themeType: "light" | "dark") {
  return {
    theme: { dark: AGENT_DIFF_THEME, light: AGENT_DIFF_THEME_LIGHT },
    themeType,
    diffStyle: "unified" as const,
    diffIndicators: "bars" as const,
    hunkSeparators: "line-info" as const,
    lineDiffType: "none" as const,
    overflow: "scroll" as const,
    // A fragment edit has no known place in its file, so its numbers would be made up.
    disableLineNumbers: !numbered,
    // The bundled page allows no WebAssembly.
    preferredHighlighter: "shiki-js" as const,
    disableFileHeader: true,
    unsafeCSS: cardUnsafeCSS,
  };
}

export function EditDiff({ file }: { file: TurnFile }) {
  const t = useT();
  registerAgentDiffTheme();
  const [copied, setCopied] = useState(false);
  // The pane's theme can switch while the card is open; syntax colors follow it.
  const [themeType, setThemeType] = useState(paneThemeType);
  useEffect(() => {
    const theme = new MutationObserver(() => setThemeType(paneThemeType()));
    theme.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    return () => theme.disconnect();
  }, []);
  const options = useMemo(
    () => ({ numbered: diffOptions(true, themeType), fragment: diffOptions(false, themeType) }),
    [themeType],
  );
  const patches = useMemo(() => file.edits.map((edit) => editPatch(file, edit)), [file]);
  // A tool call's update (its status, say) rebuilds the file; compared by text, an unchanged
  // edit keeps its parsed diff and does not paint again.
  const patchText = patches.join("\0");
  const highlighted = isHighlighted(getFiletypeFromFileName(file.displayPath));
  const diffs = useMemo(
    () =>
      patchText.split("\0").map((patch) => {
        const parsed = getSingularPatch(patch);
        return highlighted ? parsed : setLanguageOverride(parsed, "text");
      }),
    [patchText, highlighted],
  );
  const name = file.path.split("/").pop() || file.path;
  return (
    <div className="cv-edit-diff">
      <div className="cv-edit-diff__header">
        <span className="cv-edit-diff__name" title={file.path}>
          {name}
        </span>
        <span className="cv-edit-diff__add">+{file.additions}</span>
        <span className="cv-edit-diff__del">-{file.deletions}</span>
        <button
          type="button"
          className="cv-codeblock__action cv-edit-diff__copy"
          aria-label={copied ? t("code.copied") : t("code.copyDiff")}
          title={copied ? t("code.copied") : t("code.copyDiff")}
          onClick={() =>
            void copyText(patches.join("")).then(
              () => setCopied(true),
              () => setCopied(false),
            )
          }
        >
          <Copy />
        </button>
      </div>
      <div className="cv-edit-diff__body">
        {file.edits.map((edit, index) =>
          edit.hunks.length ? (
            <FileDiff
              key={edit.toolId + index}
              fileDiff={diffs[index]!}
              options={edit.numbered ? options.numbered : options.fragment}
            />
          ) : (
            <div key={edit.toolId + index} className="cv-edit-diff__empty">
              {t("changes.noLineChanges")}
            </div>
          ),
        )}
      </div>
    </div>
  );
}
