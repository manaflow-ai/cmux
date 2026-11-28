// The parts every tool-call block in the transcript shares (an edit's diff, a command's Shell block,
// a call's output): Wrap lines in its header beside Copy, a box `PREVIEW_LINES` lines tall that a
// longer block scrolls inside, and lines drawn one block each, so a wrapped line hangs under its
// first row.
import { cornerAction } from "./cornerActions";
import { memo, useMemo, useRef } from "react";
import { useT } from "../i18n";
import { useBlockWrap, type BlockKind } from "./blockWrap";
import { WrapLines } from "./icons";
import { lineCount, OUTPUT_LINE_WINDOW } from "./blockPartsModel";
import { WINDOW_CHUNK, type LineWindow } from "./lineWindow";
import { Tooltip } from "../../../ui/Tooltip";
/// The header's Wrap lines toggle for a block of `kind` (every block of the kind follows it). `shaped`
/// is the block's own state until the viewer picks (blockWrap.ts `outputWraps`), so the button shows it.
export function WrapButton({
  kind,
  shaped,
  className = cornerAction(),
}: {
  kind: BlockKind;
  shaped?: boolean;
  className?: string;
}) {
  const t = useT();
  const [wrap, toggle] = useBlockWrap(kind, shaped);
  return (
    <Tooltip label={t("changes.wrapLines")}>
      <button
        type="button"
        className={className}
        aria-pressed={wrap}
        data-fold-toggle=""
        aria-label={t("changes.wrapLines")}
        onClick={toggle}
      >
        <WrapLines />
      </button>
    </Tooltip>
  );
}

const OUTPUT_LINE_CHUNK = 64;

type FrozenLineChunk = { offset: number; lines: readonly string[] };

const sameLines = (left: readonly string[], right: readonly string[]) =>
  left.length === right.length && left.every((line, index) => line === right[index]);

/// `first` and `setsize` are a windowed box's (lineWindow.ts): each line's place in the whole block,
/// for a screen reader that meets only the lines mounted.
const LineChunk = memo(function LineChunk({
  chunk,
  last,
  first,
  setsize,
}: {
  chunk: FrozenLineChunk;
  last: boolean;
  first?: number;
  setsize?: number;
}) {
  return (
    <>
      {chunk.lines.map((line, index) => {
        return (
          // oxlint-disable-next-line react/no-array-index-key -- a line's place is stable within its frozen chunk.
          <span
            key={index}
            className="cv-line"
            role={setsize && first! + index < setsize ? "listitem" : undefined}
            aria-posinset={setsize && first! + index < setsize ? first! + index + 1 : undefined}
            aria-setsize={setsize && first! + index < setsize ? setsize : undefined}
          >
            {!last || index < chunk.lines.length - 1 ? `${line}\n` : line}
          </span>
        );
      })}
    </>
  );
});

/// `text`'s lines, each its own block so a wrapped one hangs under its first row. Each keeps its
/// newline, so the text's copy and Find read it as it was. `windowed` is for a live shell only:
/// once it has more than the tail lineWindow, the card never mounts the cold prefix on every chunk.
/// `lineWindow` is set where the lines scroll in a fixed-height box (a cut preview, not one Find opened
/// whole): only the lines it names, those in the box's view, are mounted (lineWindow.ts). It counts
/// `text`'s lines as `text.split("\n")` does.
export const Lines = memo(function Lines({
  text,
  windowed = false,
  startLine = 0,
  lineWindow,
}: {
  text: string;
  windowed?: boolean;
  /** Zero-based line number of `text` in the source string when `text` is a suffix. */
  startLine?: number;
  lineWindow?: LineWindow;
}) {
  const allLines = useMemo(() => text.split("\n"), [text]);
  // A final newline leaves an empty split element, but it does not add a line to the tail window.
  // Keep that element for rendering so the output still ends with its newline.
  const offset = windowed ? Math.max(0, lineCount(text) - OUTPUT_LINE_WINDOW) : 0;
  const previous = useRef<ReadonlyMap<number, FrozenLineChunk>>(new Map());
  const from = lineWindow?.from ?? 0;
  const to = lineWindow?.to ?? allLines.length;
  const boxed = Boolean(lineWindow);
  const chunks = useMemo(() => {
    const prior = previous.current;
    const next: FrozenLineChunk[] = [];
    const reuse = (absolute: number, end: number) => {
      const chunkLines = allLines.slice(absolute - startLine, end - startLine);
      const old = prior.get(absolute);
      next.push(old && sameLines(old.lines, chunkLines) ? old : { offset: absolute, lines: chunkLines });
    };
    if (boxed) {
      // In its box: the window's whole chunks, each kept by identity while it stays mounted.
      for (let line = from; line < to; line += WINDOW_CHUNK)
        reuse(startLine + line, startLine + Math.min(to, line + WINDOW_CHUNK));
    } else {
      // Keep chunk boundaries tied to the absolute line number. As the 400-line tail slides one
      // line at a time, only its partial first chunk changes; completed middle chunks retain their
      // object and DOM identity instead of being remounted on every output event.
      for (let absolute = startLine + offset; absolute < startLine + allLines.length;) {
        const end = Math.min(
          startLine + allLines.length,
          absolute === startLine + offset
            ? Math.ceil((absolute + 1) / OUTPUT_LINE_CHUNK) * OUTPUT_LINE_CHUNK
            : absolute + OUTPUT_LINE_CHUNK,
        );
        reuse(absolute, end);
        absolute = end;
      }
    }
    previous.current = new Map(next.map((chunk) => [chunk.offset, chunk]));
    return next;
  }, [allLines, offset, startLine, boxed, from, to]);
  const drawn = chunks.map((chunk) => (
    <LineChunk
      key={chunk.offset}
      chunk={chunk}
      last={chunk.offset + chunk.lines.length === startLine + allLines.length}
      first={chunk.offset - startLine}
      setsize={lineWindow?.setsize}
    />
  ));
  if (!lineWindow) return <>{drawn}</>;
  return (
    <>
      <span ref={lineWindow.top} className="cv-line-spacer" aria-hidden="true" style={{ height: lineWindow.before }} />
      {drawn}
      <span
        ref={lineWindow.bottom}
        className="cv-line-spacer"
        aria-hidden="true"
        style={{ height: lineWindow.after }}
      />
    </>
  );
});
