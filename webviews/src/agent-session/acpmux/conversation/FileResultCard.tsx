// An opened read or file search as a card of what it found (fileResults.ts), in place of the generic
// Input and Output body (ToolDetail.tsx). A read: the file's name and line range over its lines,
// highlighted and numbered from where the read started, the first eight under a fade with "Show all
// N lines". A text or file search: how many lines and files it found, then each file with its
// matching lines, line number first; a file name or a line opens the file in cmux as a path chip in
// a reply does (`link.openPath`; the host only takes the path, so it opens at its top). The closed row
// stays one line (ToolRow.tsx). Leo, 2026-11-05: "could we potentially do even better?"; the same web
// draws it on the Mac and the phone.
import { useMemo, useState, type ReactNode } from "react";
import { useT } from "../i18n";
import { callChipHost } from "../chips/host";
import { FileKindIcon } from "../chips/FileKindIcon";
import { useMessageScope } from "../chips/messageScope";
import { isDeniedPath, pathName } from "../chips/paths";
import { PreviewMore, usePreview } from "./BlockParts";
import { CodeLines } from "./CodeBlock";
import { CopyButton } from "./CopyButton";
import type { FileCard, ReadPeek, SearchResult } from "./fileResults";
import { useTranscriptReadOnly } from "./readOnly";
import "./FileResultCard.css";

/// Rows a search card shows (a file's line and each of its matches) before "Show all N files".
export const SEARCH_PREVIEW_ROWS = 16;

export function FileResultCard({ id, card, reveal }: { id: string; card: FileCard; reveal: number }) {
  return card.kind === "read" ? (
    <ReadCard id={id} read={card.read} reveal={reveal} />
  ) : (
    <SearchCard id={id} result={card.result} lines={card.tool === "search"} reveal={reveal} />
  );
}

/// Opens `path` in cmux on a click, where this page may: never for another machine's chat, a shared
/// read-only one, or a path on the deny list (as PathChip). Otherwise it draws as plain text.
function FileButton({
  path,
  className,
  label,
  children,
}: {
  path: string;
  className: string;
  label: string;
  children: ReactNode;
}) {
  const scope = useMessageScope();
  const readOnly = useTranscriptReadOnly();
  if (scope?.host !== undefined || readOnly || isDeniedPath(path)) return <span className={className}>{children}</span>;
  return (
    <button
      type="button"
      className={className}
      data-path={path}
      /* tooltip-allow: the row shows a short name; the tooltip names the whole path and line */
      title={label}
      onClick={() => void callChipHost("link.openPath", { path })}
    >
      {children}
    </button>
  );
}

function ReadCard({ id, read, reveal }: { id: string; read: ReadPeek; reveal: number }) {
  const t = useT();
  const lines = read.end - read.start + 1;
  const preview = usePreview(lines, reveal);
  const numbers = useMemo(
    () => Array.from({ length: lines }, (_, index) => read.start + index).join("\n"),
    [lines, read.start],
  );
  return (
    <div id={id} className="cv-edit-diff cv-filepeek">
      <div className="cv-edit-diff__header">
        <FileButton path={read.path} className="cv-filepeek__name" label={read.path}>
          <FileKindIcon path={read.path} className="cv-filepeek__icon" />
          <span className="cv-edit-diff__name">{pathName(read.path)}</span>
        </FileButton>
        <span className="cv-filepeek__range" data-find-skip>
          {lines === 1
            ? t("fileCards.oneLine", { n: read.start })
            : t("fileCards.lineRange", { start: read.start, end: read.end })}
        </span>
        <CopyButton text={read.code} label={t("code.copy")} className="cv-codeblock__action cv-edit-diff__copy" />
      </div>
      <div className="cv-filepeek__body" data-preview={preview.attribute}>
        <div className="cv-filepeek__code">
          <pre className="cv-filepeek__gutter" aria-hidden data-find-skip>
            {numbers}
          </pre>
          <CodeLines code={read.code} path={read.path} />
        </div>
      </div>
      <PreviewMore preview={preview} />
    </div>
  );
}

function SearchCard({
  id,
  result,
  lines,
  reveal,
}: {
  id: string;
  result: SearchResult;
  lines: boolean;
  reveal: number;
}) {
  const t = useT();
  const [all, setAll] = useState(reveal > 0);
  const [revealed, setRevealed] = useState(reveal);
  // Find in Chat opened the call: a match may be past the cut.
  if (reveal !== revealed) {
    setRevealed(reveal);
    if (reveal > 0) setAll(true);
  }
  const rows = result.files.reduce((sum, file) => sum + 1 + file.matches.length, 0);
  const long = rows > SEARCH_PREVIEW_ROWS;
  const files = useMemo(() => {
    if (all || !long) return result.files;
    // Whole files up to the cut, and always at least one.
    const shown = [];
    let used = 0;
    for (const file of result.files) {
      used += 1 + file.matches.length;
      if (shown.length && used > SEARCH_PREVIEW_ROWS) break;
      shown.push(file);
    }
    return shown;
  }, [all, long, result.files]);
  const summary = [
    // A text search that numbered its matches counts them; a files-only one counts files alone.
    lines && result.matches > 0 ? t("fileCards.matches", { n: result.matches }) : undefined,
    t("fileCards.files", { n: result.files.length }),
  ]
    .filter(Boolean)
    .join(" · ");
  return (
    <div id={id} className="cv-filematches" data-cut={(long && !all) || undefined}>
      <div className="cv-filematches__summary" data-find-skip>
        {summary}
      </div>
      {files.map((file) => (
        <div key={file.path} className="cv-filematches__file">
          <FileButton path={file.open} className="cv-filematches__path" label={file.open}>
            <FileKindIcon path={file.path} className="cv-filematches__icon" />
            <span className="cv-filematches__name">{file.shown}</span>
            {file.count !== undefined && (
              <span className="cv-filematches__count" data-find-skip>
                {file.count}
              </span>
            )}
          </FileButton>
          {file.matches.map((match, index) => (
            <FileButton
              key={index}
              path={file.open}
              className="cv-filematches__line"
              label={match.line === undefined ? file.open : `${file.open}:${match.line}`}
            >
              <span className="cv-filematches__number" data-find-skip>
                {match.line ?? ""}
              </span>
              <span className="cv-filematches__text">{match.text}</span>
            </FileButton>
          ))}
        </div>
      ))}
      {long && (
        <button
          type="button"
          className="cv-output-more"
          aria-expanded={all}
          data-find-skip=""
          onClick={() => setAll((value) => !value)}
        >
          {all ? t("shell.showLess") : t("fileCards.showAllFiles", { n: result.files.length })}
        </button>
      )}
    </div>
  );
}
