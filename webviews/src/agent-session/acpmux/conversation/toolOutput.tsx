// A tool call's output as the transcript shows it. Terminals colour their output and agents pass it
// on raw, so the escape codes come out ("[32m"); a call can also print a megabyte, which drawn
// whole stalls the pane. An opened call shows the output without colour codes, and only its end
// (where results and errors are) until the reader asks for all of it.
import { useMemo, useState } from "react";
import { useT } from "../i18n";

/// Terminal colour codes and terminal hyperlinks (OSC 8, `\x1b]8;;URL\x07text\x1b]8;;\x07`).
// eslint-disable-next-line no-control-regex
const ANSI = /\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g;

export const stripAnsi = (text: string) => text.replace(ANSI, "");

/// The end a long output shows: its last lines, and no more than this many characters of them.
const TAIL_LINES = 400;
const TAIL_CHARS = 40_000;

/// The end of `text` a closed-up output shows, or undefined when all of it fits.
export function outputTail(text: string): string | undefined {
  // The line break before the last TAIL_LINES lines, when there are more.
  let at = text.length;
  for (let n = 0; n < TAIL_LINES && at > 0; n++) at = text.lastIndexOf("\n", at - 1);
  const start = Math.max(at > 0 ? at + 1 : 0, text.length - TAIL_CHARS);
  return start > 0 ? text.slice(start) : undefined;
}

/// What an opened call shows of `output` (colour codes removed): its end while long, all of it
/// once `all` is set.
export function useOutput(output: string | undefined) {
  const [all, setAll] = useState(false);
  const [text, tail] = useMemo(() => {
    const text = output === undefined ? undefined : stripAnsi(output);
    return [text, text === undefined ? undefined : outputTail(text)] as const;
  }, [output]);
  return {
    text,
    shown: all || tail === undefined ? text : tail,
    cut: !all && tail !== undefined,
    long: tail !== undefined,
    all,
    toggle: () => setAll((value) => !value),
  };
}

/// Show all output / Show less under an output long enough to have been cut.
export function OutputMore({ output }: { output: ReturnType<typeof useOutput> }) {
  const t = useT();
  if (!output.long) return null;
  return (
    <button type="button" className="cv-output-more" aria-expanded={output.all} onClick={output.toggle}>
      {output.all ? t("shell.showLess") : t("shell.showAll")}
    </button>
  );
}
