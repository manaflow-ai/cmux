// An opened shell call: a "Shell" card with the folder it ran in (a leading `cd ~/wt/lanes/x &&`
// reads as "x" beside the label), Wrap lines and Copy, the command in a block of its own with its
// words in their code colors ("$ grep -nE …", shellHighlight.ts), its output (the end of a long one)
// under it and, when the command failed, its exit code between the two; a caller's `footer` closes the card. Past
// eight lines the output scrolls inside an eight-line box, its bottom edge fading while more lies
// under it, with Show all N lines to drop the cap (BlockParts.tsx), so a long or streaming output
// never pushes the transcript down; while the command runs the box follows its newest line unless
// the reader scrolled up. By default the output wraps its long lines down under their start, but a
// table keeps each printed row on its own line, columns aligned, its right edge fading while more
// lies past (blockWrap.ts `outputWraps`); Wrap lines flips every output block the other way.
import { cornerAction } from "./cornerActions";
import { memo, useLayoutEffect, useMemo, useRef, useState, type ReactNode, type RefObject } from "react";
import { useT } from "../i18n";
import { outputWraps, useBlockWrap } from "./blockWrap";
import { Lines, PreviewMore, WrapButton } from "./BlockParts";
import { lineCount, PREVIEW_LINES, SIDEWAYS_SCROLLER, usePreview, useSidewaysEdge } from "./blockPartsModel";
import { commandFolder } from "./commandFolder";
import { CopyButton } from "./CopyButton";
import { menuPartRef } from "./menuParts";
import { moreBelow, useMoreBelowOn } from "./moreBelow";
import { SHELL_ROLE_COLOR, shellTokens } from "./shellHighlight";
import { OutputMore } from "./toolOutput";
import { previewedOutput, useOutput } from "./toolOutputModel";

export function ShellBlock({
  id,
  command,
  output,
  exitCode,
  reveal,
  whole = false,
  cut,
  footer,
  live = false,
}: {
  id?: string;
  /** Bumped when Find in Chat reveals the call: shows the whole output, not only its end. */
  reveal?: number;
  command?: string;
  output?: string;
  exitCode?: number;
  /** Never cut to a preview (a command a permission ask is about). */
  whole?: boolean;
  /** The output starts after the beginning of what the command printed (a read tail). */
  cut?: boolean;
  /** The card's last line, under the exit code (a background task's Open in terminal). */
  footer?: ReactNode;
  /** The command still runs: its output may yet run past the right edge (conversation.css `data-live`). */
  live?: boolean;
}) {
  const t = useT();
  const raw = useOutput(output, reveal);
  const { folder, rest } = command ? commandFolder(command) : { folder: undefined, rest: undefined };
  const shaped = useMemo(() => outputWraps(raw.text), [raw.text]);
  const [wrap] = useBlockWrap("output", shaped);
  const body = useRef<HTMLPreElement>(null);
  // Wrapped, a few printed lines can still take more than eight rows (one 10,000-character line):
  // they are cut to eight rows too, with Show all, as a call's output is (outputViewport.ts).
  const lines = whole ? 0 : lineCount(raw.text);
  const tall = useWrappedRows(body, wrap && lines > 0 && lines <= PREVIEW_LINES);
  // The output's lines, though a long output draws only its end until opened (none to cut when whole).
  const preview = usePreview(lines, reveal, tall);
  const shown = previewedOutput(raw, preview);
  const marked = shown.cut || Boolean(cut && shown.shown);
  // `outputTail` returns a suffix, so keep the source line number alongside it. Without this,
  // every memoized chunk appears to start at line zero whenever the live 400-line window slides.
  const shownStartLine =
    raw.text && shown.shown && shown.shown !== raw.text
      ? raw.text.slice(0, raw.text.length - shown.shown.length).split("\n").length - 1
      : 0;
  useSidewaysEdge(body);
  // Following first, so the fade reads where the box ends up, not where it was.
  useFollowEnd(body, shown.shown, live && preview.cut);
  useMoreBelowOn(body, shown.shown);
  return (
    <div className="cv-shell" id={id} ref={menuPartRef({ command, output: shown.text })}>
      <div className="cv-shell__label">
        <span className="cv-shell__title">
          {t("shell.label")}
          {folder && (
            <span
              className="cv-shell__folder"
              data-find-skip
              /* tooltip-allow: the full `cd …` prefix shows nowhere else (the command line drops it) */
              title={command!.slice(0, command!.length - rest!.length).trim()}
            >
              {folder}
            </span>
          )}
        </span>
        <span className="cv-shell__actions">
          {/* One choice for every Shell block (blockWrap.ts): shown on this block's hover or focus only,
              so Verbose's open blocks don't repeat it; the chat menu's Transcript view has it at rest. */}
          <WrapButton kind="output" shaped={shaped} className={`${cornerAction()} cv-shell__wrap`} />
          {shown.text && <CopyButton text={shown.text} label={t("turn.copy")} />}
        </span>
      </div>
      {rest && <ShellCommand command={rest} />}
      {exitCode !== undefined && exitCode !== 0 && (
        // Between the command and its output, in the error tone, as Claude Code desktop opens a
        // failed call ("$ ls fixtures", "Exit code 1", then what it printed). The block's own words,
        // not the output: Find in Chat does not count them (chatFind.ts).
        <div className="cv-shell__exit" data-find-skip>
          {t("shell.exit", { code: exitCode })}
        </div>
      )}
      {/* Empty (a command with no output yet), it draws nothing (conversation.css). */}
      <pre
        ref={body}
        className="cv-shell__body selectable"
        data-wrap={wrap}
        data-preview={preview.attribute}
        data-live={live || undefined}
        {...SIDEWAYS_SCROLLER}
      >
        {marked && (
          <span className="cv-output-cut" aria-hidden="true">
            …
          </span>
        )}
        {shown.shown ? (
          <span className="cv-shell__output">
            <Lines text={shown.shown} windowed={live && !preview.all} startLine={shownStartLine} />
          </span>
        ) : null}
      </pre>
      <PreviewMore preview={preview} />
      {!preview.long && <OutputMore output={shown} />}
      {footer}
    </div>
  );
}

/**
 * The command line, its words colored by role. Memoized on the command string: the output streaming
 * under it re-renders the card, never this, so a command is tokenized once however many chunks
 * arrive (ShellBlock.test.tsx). Its words are one Find run (`data-find-join`), so a match may span
 * the colored parts as it spans the words; the `$ ` prompt is not the command's text, so Find and a
 * selection's copy skip it.
 */
export const ShellCommand = memo(function ShellCommand({ command }: { command: string }) {
  const lines: ReactNode[][] = [[]];
  for (const [index, token] of shellTokens(command).entries()) {
    const parts = token.text.split("\n");
    for (const [at, part] of parts.entries()) {
      if (at > 0) lines.push([]);
      const text = at < parts.length - 1 ? `${part}\n` : part;
      if (!text) continue;
      const line = lines[lines.length - 1]!;
      line.push(
        token.role ? (
          // oxlint-disable-next-line react/no-array-index-key -- a token's place is its identity.
          <span key={`${index}.${at}`} data-role={token.role} style={{ color: SHELL_ROLE_COLOR[token.role] }}>
            {text}
          </span>
        ) : (
          text
        ),
      );
    }
  }
  return (
    <pre className="cv-shell__command selectable" data-find-join="">
      {lines.map((line, index) => (
        // oxlint-disable-next-line react/no-array-index-key -- a line's place is its identity.
        <span key={index} className="cv-line">
          {index === 0 && (
            <span className="cv-shell__prompt" data-find-skip="" aria-hidden="true">
              ${" "}
            </span>
          )}
          {line}
        </span>
      ))}
    </pre>
  );
});

/// Whether the output in `ref` takes more than `PREVIEW_LINES` rows, while `watching` (wrapped, with
/// no more printed lines than the cap: more lines are cut by their count). It measures the output
/// span, whose height the box's own cap never changes, once on mount and on each resize, so a reflow
/// (the font loading, the pane narrowing) or a streamed chunk updates it.
function useWrappedRows(ref: RefObject<HTMLElement | null>, watching: boolean): boolean {
  const [tall, setTall] = useState(false);
  useLayoutEffect(() => {
    const box = ref.current;
    if (!box || !watching) return;
    const measure = () => {
      const output = box.querySelector(".cv-shell__output");
      const row = parseFloat(box.ownerDocument.defaultView?.getComputedStyle(box).lineHeight ?? "");
      setTall(Boolean(output && row > 0 && output.getBoundingClientRect().height > PREVIEW_LINES * row + 1));
    };
    measure();
    const view = box.ownerDocument.defaultView;
    if (!view?.ResizeObserver) return;
    const sized = new view.ResizeObserver(measure);
    sized.observe(box);
    const watched = new Set<Element>();
    const watchOutput = () => {
      const output = box.querySelector(".cv-shell__output");
      if (output && !watched.has(output)) {
        watched.add(output);
        sized.observe(output);
      }
      measure();
    };
    watchOutput();
    const changed = new view.MutationObserver(watchOutput);
    changed.observe(box, { childList: true });
    return () => {
      sized.disconnect();
      changed.disconnect();
    };
  }, [ref, watching]);
  return watching && tall;
}

/// While `following`, keeps the box scrolled to its newest line as `content` grows, unless the
/// reader scrolled up from the end; scrolling back to the end follows again. A late reflow (the mono
/// font loading, the pane resizing) grows the content without a scroll, so a resize of the box or
/// of its output pins the end again too. The output span may be a new node after any change (it
/// goes when the output empties), so each change re-aims the observer at the current one. One
/// scroll listener and one ResizeObserver for as long as it follows, and per change of `content`
/// one lookup of the output and one assignment.
function useFollowEnd(ref: RefObject<HTMLElement | null>, content: unknown, following: boolean) {
  const away = useRef(false);
  const watch = useRef<{ resize: ResizeObserver; output: Element | null } | null>(null);
  useLayoutEffect(() => {
    const box = ref.current;
    if (!box || !following) return;
    const onScroll = () => {
      away.current = moreBelow(box);
    };
    box.addEventListener("scroll", onScroll, { passive: true });
    const view = box.ownerDocument.defaultView;
    if (view?.ResizeObserver) {
      const resize = new view.ResizeObserver(() => {
        if (!away.current) box.scrollTop = box.scrollHeight;
      });
      resize.observe(box);
      watch.current = { resize, output: null };
    }
    return () => {
      box.removeEventListener("scroll", onScroll);
      watch.current?.resize.disconnect();
      watch.current = null;
    };
  }, [ref, following]);
  useLayoutEffect(() => {
    const box = ref.current;
    if (!box || !following) return;
    const current = watch.current;
    const output = box.querySelector(".cv-shell__output");
    if (current && output !== current.output) {
      if (current.output) current.resize.unobserve(current.output);
      if (output) current.resize.observe(output);
      current.output = output;
    }
    if (!away.current) box.scrollTop = box.scrollHeight;
  }, [ref, content, following]);
}
