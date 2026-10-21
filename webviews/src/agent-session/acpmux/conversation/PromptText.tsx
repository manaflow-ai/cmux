// A sent prompt's text in its bubble (UserBubble.tsx). A prompt taller than ten lines opens on
// them, the last ones fading out under a mask, with Show more under them and Show less once open,
// as Claude's does (Leo 2026-10-21). A block the composer sent as a paste is a chip, the composer's
// attachment chip without its ×: "<first words> · N lines", which opens the paste in place. Each
// choice is kept by the row's id (transcriptDisclosure.tsx), so a prompt scrolled out and back, or
// drawn again from history, stays as the reader left it. Find opens a collapsed prompt, or a closed
// chip, that holds its current match. The bubble keeps the whole text; Copy copies all of it.
import { useContext, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useT, usePaneLanguage } from "../i18n";
import { FindReveal } from "./chatFind";
import {
  COLLAPSED_PROMPT_LINES,
  type PasteRange,
  looksLongPrompt,
  pasteLines,
  pasteName,
  promptParts,
} from "./promptCollapse";
import { useTranscriptDisclosure } from "./transcriptDisclosure";

export function PromptText({
  rowId,
  text,
  pasted,
  show,
}: {
  rowId: string;
  /// The prompt as recorded: what Find searches and the paste ranges point into.
  text: string;
  pasted?: readonly PasteRange[];
  /// How a typed part reads in the bubble (a `data:` image as its name, UserBubble.tsx).
  show: (text: string) => string;
}) {
  const t = useT();
  const id = useId();
  const parts = useMemo(() => promptParts(text, pasted ?? []), [text, pasted]);
  const [open, setOpen] = useTranscriptDisclosure(`prompt:${rowId}`);
  // Whether the prompt is taller than the collapsed lines: guessed from its text until laid out,
  // then measured against its line height (open or closed), again when its width changes.
  const [long, setLong] = useState(() => looksLongPrompt(pasted?.length ? "" : text) || parts.length > 3);
  const body = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const node = body.current;
    if (!node) return;
    const measure = () => {
      const lineHeight = parseFloat(getComputedStyle(node).lineHeight);
      // No layout (a test DOM) keeps the guess.
      if (!node.scrollHeight || !Number.isFinite(lineHeight)) return;
      setLong(node.scrollHeight > COLLAPSED_PROMPT_LINES * lineHeight + 1);
    };
    measure();
    if (typeof ResizeObserver !== "function") return;
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    return () => observer.disconnect();
  }, [text, pasted]);
  const collapsed = long && !open;
  // Find's current match in this prompt opens it; one in a typed part past the fold, or in a paste,
  // needs it open to draw.
  const reveal = useContext(FindReveal);
  const needle = reveal && reveal.rowId === rowId ? reveal.needle : "";
  const hit = Boolean(needle && text.toLocaleLowerCase().includes(needle));
  useLayoutEffect(() => {
    if (!hit || !collapsed) return;
    setOpen(true);
    reveal?.repaint();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new match opens, not a new callback
  }, [hit, reveal]);
  return (
    <>
      <div ref={body} id={id} className={`cv-user__text${collapsed ? " is-clamped is-faded" : ""}`}>
        {parts.map((part, index) =>
          part.kind === "text" ? (
            <span key={index} className="cv-user__typed">
              {show(part.text)}
            </span>
          ) : (
            <PasteChip
              key={index}
              rowId={rowId}
              index={part.index}
              text={part.text}
              needle={needle}
              // An opened paste shows whole, not cut at the prompt's tenth line.
              onOpen={() => setOpen(true)}
            />
          ),
        )}
      </div>
      {long && (
        <button
          type="button"
          className="cv-user__more"
          aria-expanded={!collapsed}
          aria-controls={id}
          data-find-skip=""
          onClick={() => setOpen(collapsed)}
        >
          {t(collapsed ? "message.more" : "message.less")}
        </button>
      )}
    </>
  );
}

/// One pasted block: the chip, and the paste under it once opened.
function PasteChip({
  rowId,
  index,
  text,
  needle,
  onOpen,
}: {
  rowId: string;
  index: number;
  text: string;
  needle: string;
  onOpen: () => void;
}) {
  const t = useT();
  const language = usePaneLanguage();
  const id = useId();
  const [open, setOpen] = useTranscriptDisclosure(`prompt:${rowId}:paste:${index}`);
  const hit = Boolean(needle && text.toLocaleLowerCase().includes(needle));
  const reveal = useContext(FindReveal);
  useLayoutEffect(() => {
    if (!hit || open) return;
    setOpen(true);
    reveal?.repaint();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new match opens, not a new callback
  }, [hit, reveal]);
  const lines = pasteLines(text);
  const count = new Intl.NumberFormat(language).format(lines);
  return (
    <span className="cv-user__paste-block">
      <button
        type="button"
        className="acpmux-attachment acpmux-attachment-file acpmux-attachment-link cv-user__paste"
        aria-expanded={open}
        aria-controls={id}
        onClick={() => {
          if (!open) onOpen();
          setOpen(!open);
        }}
      >
        <span className="cv-user__paste-name">{pasteName(text)}</span>
        <span className="acpmux-attachment-link-note cv-user__paste-lines">
          {t("transcript.pastedLines", { n: lines, count })}
        </span>
      </button>
      {open && (
        <span id={id} className="cv-user__paste-text">
          {text}
        </span>
      )}
    </span>
  );
}
