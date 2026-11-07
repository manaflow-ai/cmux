// A tool call's output as the transcript shows it. Terminals colour their output and agents pass it
// on raw, so the escape codes come out ("[32m"); a call can also print a megabyte, which drawn
// whole stalls the pane. An opened call shows the output without colour codes, and only its end
// (where results and errors are) until the reader asks for all of it.

import { useT } from "../i18n";
import { useOutput } from "./toolOutputModel";
/// Show all output / Show less under an output long enough to have been cut (and too few lines for
/// a preview, which opens it instead: BlockParts.tsx `PreviewMore`). Find skips its words.
export function OutputMore({ output }: { output: ReturnType<typeof useOutput> }) {
  const t = useT();
  if (!output.long) return null;
  return (
    <button
      type="button"
      className="cv-output-more"
      aria-expanded={output.all}
      data-find-skip=""
      onClick={output.toggle}
    >
      {output.all ? t("shell.showLess") : t("shell.showAll")}
    </button>
  );
}
