// An opened read or file search as a card of what it found (fileResults.ts), in place of the generic
// Input and Output body (ToolDetail.tsx). A read: the file's name and line range over its lines,
// highlighted and numbered from where the read started. A text or file search: how many lines and
// files it found, then each file with its matching lines, line number first. Either draws whole up
// to `OUTPUT_BOX_LINES` rows and scrolls inside a box that tall past them (outputScrollBox.css),
// never behind a Show all button; a file name or a line opens the file in cmux as a path chip in
// a reply does (`link.openPath`; the host only takes the path, so it opens at its top). The closed row
// stays one line (ToolRow.tsx). Leo, 2026-11-05: "could we potentially do even better?"; the same web
// draws it on the Mac and the phone.
import { cornerAction } from "./cornerActions";
import { useCallback, useMemo, type ReactNode } from "react";
import { useT } from "../i18n";
import { callChipHost } from "../chips/host";
import { FileKindIcon } from "../chips/FileKindIcon";
import { usePathInfo } from "../chips/linkStore";
import { useMessageScope } from "../chips/messageScope";
import { isDeniedPath, pathName } from "../chips/paths";
import { OUTPUT_SCROLL_BOX } from "./blockPartsModel";
import { CodeLines } from "./CodeBlock";
import { CopyButton } from "./CopyButton";
import type { FileCard, ReadPeek, SearchFile, SearchResult } from "./fileResults";
import { watchOutputViewport } from "./outputViewport";
import { useTranscriptReadOnly } from "./readOnly";
import "./FileResultCard.css";
import "./outputScrollBox.css";

/// Rows a search card mounts (a file's line and each of its matches): a search with thousands of
/// matches never mounts more than this; the summary counts all of them.
const SEARCH_MOUNTED_ROWS = 2_000;

/// `reveal` (Find in Chat revealed the call) needs nothing here: every line is drawn already.
export function FileResultCard({ id, card }: { id: string; card: FileCard; reveal?: number }) {
  return card.kind === "read" ? (
    <ReadCard id={id} read={card.read} />
  ) : (
    <SearchCard id={id} result={card.result} lines={card.tool === "search"} />
  );
}

/// The ref of a card body that scrolls in its box: it keeps the box's edge marks current (moreBelow.ts).
const useScrollBox = () =>
  useCallback((node: HTMLElement | null) => (node ? watchOutputViewport(node) : undefined), []);

/// Opens `path` in cmux on a click, where this page may: never for another machine's chat, a shared
/// read-only one, or a path on the deny list (as PathChip). Otherwise it draws as plain text.
function FileButton(props: { path: string; className: string; label: string; children: ReactNode }) {
  const scope = useMessageScope();
  const readOnly = useTranscriptReadOnly();
  if (scope?.host !== undefined || readOnly || isDeniedPath(props.path))
    return <span className={props.className}>{props.children}</span>;
  return <HostFileButton {...props} />;
}

/// A file the host has placed (`link.inspect`, linkStore.ts): a button once it answers that the path
/// is in the session's folders, or outside them where `agentPane.links.outsideRoots` lets it open.
/// A chat on another machine gets no place for its paths, so its files stay text, as do missing and
/// denied ones; until the host answers, the line is text too, so a click never goes nowhere.
function HostFileButton({
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
  const { info, answered, policy } = usePathInfo(path);
  const opens = answered && (info?.place === "root" || (info?.place === "outside" && policy.outsideRoots !== "text"));
  if (!opens) return <span className={className}>{children}</span>;
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

function ReadCard({ id, read }: { id: string; read: ReadPeek }) {
  const t = useT();
  const lines = read.end - read.start + 1;
  const box = useScrollBox();
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
        <CopyButton text={read.code} label={t("code.copy")} className={`${cornerAction()} cv-edit-diff__copy`} />
      </div>
      <div
        ref={box}
        className={`cv-filepeek__body ${OUTPUT_SCROLL_BOX}`}
        // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- focus the scroll box to read it with arrow keys.
        tabIndex={0}
      >
        <div className="cv-filepeek__code">
          <pre className="cv-filepeek__gutter" aria-hidden data-find-skip>
            {numbers}
          </pre>
          <CodeLines code={read.code} path={read.path} />
        </div>
      </div>
    </div>
  );
}

function SearchCard({ id, result, lines }: { id: string; result: SearchResult; lines: boolean }) {
  const t = useT();
  const box = useScrollBox();
  const rows = result.files.reduce((sum, file) => sum + 1 + file.matches.length, 0);
  const files = useMemo(() => {
    if (rows <= SEARCH_MOUNTED_ROWS) return result.files;
    // Files up to the cap, the last one's matches cut with it, so one file with a huge number of
    // matches never mounts them all.
    const shown: SearchFile[] = [];
    let left = SEARCH_MOUNTED_ROWS;
    for (const file of result.files) {
      if (left <= 0) break;
      const matches = file.matches.slice(0, Math.max(0, left - 1));
      shown.push(matches.length < file.matches.length ? { ...file, matches } : file);
      left -= 1 + matches.length;
    }
    return shown;
  }, [rows, result.files]);
  const summary = [
    // A text search that numbered its matches counts them; a files-only one counts files alone.
    lines && result.matches > 0 ? t("fileCards.matches", { n: result.matches }) : undefined,
    t("fileCards.files", { n: result.files.length }),
    // The harness cut its own list short: the card says so rather than look complete.
    result.truncated ? t("fileCards.truncated") : undefined,
  ]
    .filter(Boolean)
    .join(" · ");
  return (
    <div id={id} className="cv-filematches">
      <div
        ref={box}
        className={`cv-filematches__list ${OUTPUT_SCROLL_BOX}`}
        // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- focus the scroll box to read it with arrow keys.
        tabIndex={0}
      >
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
      </div>
    </div>
  );
}
