// A sent prompt's text in its bubble (UserBubble.tsx). A prompt taller than ten lines opens on
// them, the last ones fading out under a mask, with Show more under them and Show less once open,
// as Claude's does (Leo 2026-10-21). A block the composer sent as a paste is a chip, the composer's
// attachment chip without its ×: "<first words> · N lines", which opens the paste in place. Each
// choice is kept by the row's id (transcriptDisclosure.tsx), so a prompt scrolled out and back, or
// drawn again from history, stays as the reader left it. Find opens a collapsed prompt, or a closed
// chip, that holds its current match. The bubble keeps the whole text; Copy copies all of it.
import { useContext, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
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
import { foldMotion, foldMs, markHeightFold } from "./fold";
import { holdHeader } from "./useAnchoredCollapse";
import { Markdown } from "./Markdown";

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
  // then measured against its line height (open or closed), again when its width changes. A
  // measure is of one text: a bubble drawn again with another prompt guesses again.
  const guess = looksLongPrompt(pasted?.length ? "" : text) || parts.length > 3;
  const [measured, setMeasured] = useState<{ parts: typeof parts; long: boolean }>();
  const long = measured?.parts === parts ? measured.long : guess;
  const body = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const node = body.current;
    if (!node) return;
    const measure = () => {
      // The node's own window: a test DOM may install none as a global.
      const style = node.ownerDocument.defaultView?.getComputedStyle?.(node);
      const lineHeight = parseFloat(style?.lineHeight ?? "");
      // Clamped, the text is a box that scrolls; drawn whole it is no box of its own (CSS
      // `display: contents`, so the bubble insets its text as before), and its lines measure it.
      let height = node.scrollHeight;
      if (!node.classList.contains("is-clamped")) {
        const range = node.ownerDocument.createRange();
        range.selectNodeContents(node);
        height = typeof range.getBoundingClientRect === "function" ? range.getBoundingClientRect().height : 0;
      }
      // No layout (a test DOM) keeps the guess.
      if (!height || !Number.isFinite(lineHeight)) return;
      const next = height > COLLAPSED_PROMPT_LINES * lineHeight + 1;
      setMeasured((last) => (last?.parts === parts && last.long === next ? last : { parts, long: next }));
    };
    measure();
    if (typeof ResizeObserver !== "function") return;
    const observer = new ResizeObserver(measure);
    // The bubble: a text drawn whole has no box to observe.
    observer.observe(node.parentElement ?? node);
    return () => observer.disconnect();
  }, [parts, long, open]);
  const collapsed = long && !open;
  // Show more and Show less (Leo 2026-10-21: "these all need animations for expand and collpase"),
  // over the fold's token, without moving what the reader looks at ("just expand the area at the
  // bottom and you're in the same place"):
  // - Show more holds the bubble's top: the text grows below it, and the button rides the bubble's
  //   bottom edge down instead of jumping there.
  // - Show less holds the button, where the reader clicked it: the text shrinks back above it into
  //   its first lines, fully drawn until it is clipped.
  // A toggle midway starts from the drawn height; unmounting cancels what plays.
  const resized = useRef<number | undefined>(undefined);
  const resizing = useRef<Animation[]>([]);
  const stopResize = () => {
    for (const animation of resizing.current) animation.cancel();
    resizing.current = [];
  };
  useEffect(() => stopResize, []);
  const more = () => body.current?.parentElement?.querySelector<HTMLElement>(":scope > .cv-user__more") ?? null;
  const showMore = (next: boolean) => {
    const bubble = body.current?.parentElement;
    if (bubble) {
      holdHeader(next ? bubble : (more() ?? bubble));
      resized.current = bubble.getBoundingClientRect().height;
    }
    stopResize();
    setOpen(next);
  };
  useLayoutEffect(() => {
    const from = resized.current;
    resized.current = undefined;
    const bubble = body.current?.parentElement;
    const text = body.current;
    const ms = foldMs(bubble ?? null);
    if (from === undefined || !bubble || !text || ms <= 0) return;
    const to = bubble.getBoundingClientRect().height;
    if (Math.abs(to - from) < 1) return;
    const timing = { duration: ms, easing: foldMotion.easing(bubble) };
    // The rows below are placed before paint while the bubble resizes, as under a fold.
    markHeightFold(bubble, ms);
    if (collapsed) {
      // The clamped text is a box again: it starts as tall as the whole text was drawn.
      const clamped = text.getBoundingClientRect().height;
      resizing.current.push(
        text.animate(
          [
            { height: `${clamped + from - to}px`, maxHeight: "none" },
            { height: `${clamped}px`, maxHeight: "none" },
          ],
          timing,
        ),
      );
      return;
    }
    resizing.current.push(
      bubble.animate(
        [
          { height: `${from}px`, overflow: "hidden" },
          { height: `${to}px`, overflow: "hidden" },
        ],
        timing,
      ),
    );
    const button = more();
    if (button)
      resizing.current.push(button.animate([{ translate: `0 ${from - to}px` }, { translate: "0 0" }], timing));
  }, [collapsed]);
  // Find's current match in this prompt opens it; one in a typed part past the fold, or in a paste,
  // needs it open to draw.
  const reveal = useContext(FindReveal);
  const needle = reveal && reveal.rowId === rowId ? reveal.needle : "";
  const hit = Boolean(needle && text.toLocaleLowerCase().includes(needle));
  useLayoutEffect(() => {
    if (!hit || !collapsed) return;
    setOpen(true);
    reveal?.repaint();
    // A prompt found long only once laid out (a paste, a narrow wrap) opens then; Show less after
    // that stays shut.
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new match opens, not a new callback
  }, [hit, reveal, long]);
  return (
    <>
      <div ref={body} id={id} className={`cv-user__text${collapsed ? " is-clamped is-faded" : ""}`}>
        {parts.map((part, index) =>
          part.kind === "text" ? (
            /(^|\n)\s*>/.test(part.text) ? (
              <Markdown key={index} className="cv-user__markdown" thumbnails={false}>
                {show(part.text)}
              </Markdown>
            ) : (
              <span key={index} className="cv-user__typed">
                {show(part.text)}
              </span>
            )
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
          onClick={() => showMore(collapsed)}
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
        // Its name and count are labels, not the prompt's text: Find counts matches in `text`
        // (chatFind.ts findMatches), so it paints none here.
        data-find-skip=""
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
