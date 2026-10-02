// An opened edit as Codex draws it inside the transcript: a card per changed file with its
// name, the lines added and removed, copy, and the change on @pierre/diffs, scrolling past a
// few lines. The changes view (changes/EditBlock.tsx) draws the same edits at full size.
import { useMemo, useState } from "react";
import { getFiletypeFromFileName, getSingularPatch, setLanguageOverride } from "@pierre/diffs";
import { FileDiff } from "@pierre/diffs/react";
import { editPatch, type TurnFile } from "../diff";
import { AGENT_DIFF_THEME, AGENT_DIFF_THEME_LIGHT, diffUnsafeCSS, registerAgentDiffTheme } from "../diffTheme";
import { isHighlighted } from "../shikiLanguages";
import { copyText } from "./clipboard";
import { Copy } from "./icons";

/// The pane's theme (applyAgentTheme) is light or dark; syntax colors follow it.
const paneThemeType = () =>
  document.documentElement.dataset.theme === "light" ? ("light" as const) : ("dark" as const);

/// Pierre's options for an edit placed in its file (numbered) and for a bare fragment.
function diffOptions(numbered: boolean) {
  return {
    theme: { dark: AGENT_DIFF_THEME, light: AGENT_DIFF_THEME_LIGHT },
    themeType: paneThemeType(),
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
    unsafeCSS: diffUnsafeCSS,
  };
}

export function EditDiff({ file }: { file: TurnFile }) {
  registerAgentDiffTheme();
  const [copied, setCopied] = useState(false);
  const options = useMemo(() => ({ numbered: diffOptions(true), fragment: diffOptions(false) }), []);
  const patches = useMemo(() => file.edits.map((edit) => editPatch(file, edit)), [file]);
  const highlighted = isHighlighted(getFiletypeFromFileName(file.displayPath));
  const diffs = useMemo(
    () =>
      patches.map((patch) => {
        const parsed = getSingularPatch(patch);
        return highlighted ? parsed : setLanguageOverride(parsed, "text");
      }),
    [patches, highlighted],
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
          aria-label={copied ? "Copied" : "Copy diff"}
          title={copied ? "Copied" : "Copy diff"}
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
              No line changes
            </div>
          ),
        )}
      </div>
    </div>
  );
}
