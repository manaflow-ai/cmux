// The parts every tool-call block in the transcript shares (an edit's diff, a command's Shell block,
// a call's output): Wrap lines in its header beside Copy, the first `PREVIEW_LINES` lines under a
// fade with "Show all N lines" below, and lines drawn one block each, so a wrapped line hangs under
// its first row.
import { cornerAction } from "./cornerActions";
import { memo, useMemo, useRef } from "react";
import { useT } from "../i18n";
import { useBlockWrap, type BlockKind } from "./blockWrap";
import { ExpandRow } from "./ExpandRow";
import { WrapLines } from "./icons";
import { usePreview, lineCount, OUTPUT_LINE_WINDOW } from "./blockPartsModel";
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
  );
}

/// "Show all N lines" under a cut block, "Show less" once it is open. A block that draws only the
/// end of a long output counts all of its lines, and opened it draws them all (toolOutput.tsx
/// `previewedOutput`), so N is never the tail's count. It is the block's whole bottom row (ExpandRow.tsx).
export function PreviewMore({ preview }: { preview: ReturnType<typeof usePreview> }) {
  const t = useT();
  if (!preview.long) return null;
  return (
    <ExpandRow
      className="cv-output-more"
      open={preview.all}
      onToggle={preview.toggle}
      label={preview.all ? t("shell.showLess") : t("transcript.showAllLines", { n: preview.lines })}
    />
  );
}

const OUTPUT_LINE_CHUNK = 64;

type FrozenLineChunk = { offset: number; lines: readonly string[] };

const sameLines = (left: readonly string[], right: readonly string[]) =>
  left.length === right.length && left.every((line, index) => line === right[index]);

const LineChunk = memo(function LineChunk({ chunk, last }: { chunk: FrozenLineChunk; last: boolean }) {
  return (
    <>
      {chunk.lines.map((line, index) => {
        return (
          // oxlint-disable-next-line react/no-array-index-key -- a line's place is stable within its frozen chunk.
          <span key={index} className="cv-line">
            {!last || index < chunk.lines.length - 1 ? `${line}\n` : line}
          </span>
        );
      })}
    </>
  );
});

/// `text`'s lines, each its own block so a wrapped one hangs under its first row. Each keeps its
/// newline, so the text's copy and Find read it as it was. `windowed` is for a live shell only:
/// once it has more than the tail window, the card never mounts the cold prefix on every chunk.
export const Lines = memo(function Lines({
  text,
  windowed = false,
  startLine = 0,
}: {
  text: string;
  windowed?: boolean;
  /** Zero-based line number of `text` in the source string when `text` is a suffix. */
  startLine?: number;
}) {
  const allLines = useMemo(() => text.split("\n"), [text]);
  // A final newline leaves an empty split element, but it does not add a line to the tail window.
  // Keep that element for rendering so the output still ends with its newline.
  const offset = windowed ? Math.max(0, lineCount(text) - OUTPUT_LINE_WINDOW) : 0;
  const previous = useRef<ReadonlyMap<number, FrozenLineChunk>>(new Map());
  const chunks = useMemo(() => {
    const prior = previous.current;
    const next: FrozenLineChunk[] = [];
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
      const chunkLines = allLines.slice(absolute - startLine, end - startLine);
      const old = prior.get(absolute);
      next.push(old && sameLines(old.lines, chunkLines) ? old : { offset: absolute, lines: chunkLines });
      absolute = end;
    }
    previous.current = new Map(next.map((chunk) => [chunk.offset, chunk]));
    return next;
  }, [allLines, offset, startLine]);
  return (
    <>
      {chunks.map((chunk) => (
        <LineChunk
          key={chunk.offset}
          chunk={chunk}
          last={chunk.offset + chunk.lines.length === startLine + allLines.length}
        />
      ))}
    </>
  );
});
