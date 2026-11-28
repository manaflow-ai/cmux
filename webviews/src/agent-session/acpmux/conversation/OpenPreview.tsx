// The code card's Open (cx-ncc.63): an HTML, SVG or Markdown fence opens in the side panel beside the
// chat (ArtifactPanel.tsx). Apart from the panel, so the code card does not import the panel that
// draws code cards.
import { useContext } from "react";
import { useT } from "../i18n";
import { ArtifactContext, artifactKind } from "./artifactPreview";
import { Expand } from "./icons";

/// The code card's Open: a fence the panel can draw opens there; any other fence has none.
export function OpenPreview({ code, lang }: { code: string; lang?: string }) {
  const t = useT();
  const open = useContext(ArtifactContext);
  const kind = artifactKind(lang, code);
  if (!open || !kind) return null;
  return (
    <button
      type="button"
      className="cv-codeblock__action"
      aria-label={t("artifact.open")}
      title={t("artifact.open")}
      onClick={() => open({ kind, lang: lang ?? kind, code })}
    >
      <Expand />
    </button>
  );
}
