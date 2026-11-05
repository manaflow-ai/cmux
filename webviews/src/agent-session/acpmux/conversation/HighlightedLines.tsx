// A read file's bare lines (FileResultCard.tsx), highlighted by its name's language in the fenced
// card's Pierre setup (HighlightedCode.tsx `usePierreCode`). Its own module, loaded with the card's
// chunk (CodeBlock.tsx `CodeLines`), so the fenced card's imports stay what they were.
import { getFiletypeFromFileName } from "@pierre/diffs";
import { isHighlighted } from "../shikiLanguages";
import { codeUnsafeCSS, DiffsHost, usePierreCode } from "./HighlightedCode";
import { PlainCodeLines } from "./StreamingCode";

/// A read file's lines, highlighted by its name's language, with no card chrome and no wrapping, so
/// each line keeps the code line height its gutter's numbers are set on (FileResultCard.tsx). Plain
/// lines until Pierre has painted, and for good when it cannot.
export function HighlightedLines({ code, path }: { code: string; path: string }) {
  const type = getFiletypeFromFileName(path);
  const lang = isHighlighted(type) ? type : "text";
  const { host, painted, workerAvailable } = usePierreCode(code, lang, codeUnsafeCSS, false);
  return (
    <div className="cv-filepeek__lines">
      {(!workerAvailable || !painted) && <PlainCodeLines code={code} />}
      {workerAvailable && (
        <DiffsHost
          ref={host}
          className="selectable"
          style={!painted ? { position: "absolute", inset: "0 0 auto", visibility: "hidden" } : undefined}
        />
      )}
    </div>
  );
}
