// A tool call's output as the transcript shows it. Terminals colour their output and agents pass it
// on raw, so the escape codes come out ("[32m"); a call can also print a megabyte, which drawn
// whole stalls the pane. An opened call shows the output without colour codes, and only its end
// (where results and errors are) until the reader asks for all of it.
import { useMemo, useState } from "react";
import { useT } from "../i18n";

/// Terminal control codes: CSI sequences (colours, `\x1b[?25l`, `\x1b[2~`, `\x1b[0 q`), OSC
/// strings such as hyperlinks (`\x1b]8;;URL\x07text\x1b]8;;\x07`), charset picks (`tput sgr0`
/// writes `\x1b(B`) and the two-byte keypad and cursor-save codes. Each starts with ESC, so no
/// plain text is taken.
// eslint-disable-next-line no-control-regex
const ANSI = /\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()*+][0-9A-Za-z]|\x1b[=>78DEHM]/g;

export const stripAnsi = (text: string) => text.replace(ANSI, "");

/// The end a long output shows: its last lines, and no more than this many characters of them.
const TAIL_LINES = 400;
const TAIL_CHARS = 40_000;

/// The end of `text` a closed-up output shows, or undefined when all of it fits.
export function outputTail(text: string): string | undefined {
  // The line break before the last TAIL_LINES lines, when there are more; a final newline ends
  // the last line rather than starting another.
  let at = text.endsWith("\n") ? text.length - 1 : text.length;
  for (let n = 0; n < TAIL_LINES && at > 0; n++) at = text.lastIndexOf("\n", at - 1);
  let start = Math.max(at > 0 ? at + 1 : 0, text.length - TAIL_CHARS);
  // A cut inside one long line must not split a surrogate pair.
  if (start > 0 && /[\uDC00-\uDFFF]/.test(text[start] ?? "")) start++;
  return start > 0 ? text.slice(start) : undefined;
}

/// What an opened call shows of `output` (colour codes removed): its end while long, all of it
/// once the reader asks. Each new `reveal` (Find in Chat revealed the call, and a match may be in
/// the head) shows all of it too; the reader can still close it up.
export function useOutput(output: string | undefined, reveal = 0) {
  const [all, setAll] = useState(reveal > 0);
  const [revealed, setRevealed] = useState(reveal);
  if (reveal !== revealed) {
    setRevealed(reveal);
    if (reveal > 0) setAll(true);
  }
  const [text, tail] = useMemo(() => {
    const text = output === undefined ? undefined : stripAnsi(output);
    return [text, text === undefined ? undefined : outputTail(text)] as const;
  }, [output]);
  return {
    text,
    tail,
    shown: all || tail === undefined ? text : tail,
    cut: !all && tail !== undefined,
    long: tail !== undefined,
    all,
    toggle: () => setAll((value) => !value),
  };
}

/// What a block with a preview (BlockParts.tsx) draws of `output`: while it has more lines than
/// the preview shows, the preview alone decides, all of them once opened and the end of a long one
/// while cut, so an output opened while short stays whole as it streams past the end it would draw.
export function previewedOutput(
  output: ReturnType<typeof useOutput>,
  preview: { long: boolean; all: boolean },
): ReturnType<typeof useOutput> {
  if (!preview.long) return output;
  const all = preview.all;
  return {
    ...output,
    all,
    shown: all || output.tail === undefined ? output.text : output.tail,
    cut: !all && output.tail !== undefined,
  };
}

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
