// A read file's bare lines (FileResultCard.tsx), highlighted by its name's language in the fenced
// card's Pierre setup (HighlightedCode.tsx `usePierreCode`). Its own module, loaded lazily
// (CodeBlock.tsx `CodeLines`), so the fenced card's imports stay what they were.
import { fileLanguage } from "../shikiLanguages";
import { DiffsHost, usePierreCode, type PierreLineWindow } from "./usePierreCode";
import { codeUnsafeCSS } from "./highlightedCodeModel";
import { PlainCodeLines } from "./StreamingCode";
import type { LineWindow } from "./lineWindow";

/// A read file's lines, highlighted by its name's language, with no card chrome and no wrapping, so
/// each line keeps the code line height its gutter's numbers are set on (FileResultCard.tsx). Plain
/// lines until Pierre has painted, and for good when it cannot. In a long read's box, Pierre mounts
/// only the lines in its view (`pierreWindow`), and the plain lines before it are windowed too
/// (`lineWindow`, lineWindow.ts).
export function HighlightedLines({
  code,
  path,
  lineWindow,
  pierreWindow,
}: {
  code: string;
  path: string;
  lineWindow?: LineWindow;
  pierreWindow?: PierreLineWindow;
}) {
  const lang = fileLanguage(path);
  const { host, painted, workerAvailable } = usePierreCode(code, lang, codeUnsafeCSS, false, pierreWindow);
  return (
    <div className="cv-filepeek__lines">
      {(!workerAvailable || !painted) && <PlainCodeLines code={code} lineWindow={lineWindow} />}
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
