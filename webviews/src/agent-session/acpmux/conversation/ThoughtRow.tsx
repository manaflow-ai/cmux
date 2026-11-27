import { memo, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";
import type { AcpmuxActivity } from "../model";
import { useT } from "../i18n";
import { useFindReveal } from "./chatFind";
import { Brain } from "./icons";
import { playResize } from "./fold";
import { useAnchoredCollapse, type AnchoredCollapse } from "./useAnchoredCollapse";
import { useTranscriptViewContext } from "./transcriptDisclosureModel";
import { formatDuration } from "./turns";
import { isQuietThought, thoughtDuration, thoughtParts } from "./thoughts";
import { THOUGHT_LIVE_PX, thoughtHead, thoughtLayout, thoughtName } from "./thoughtRowModel";
import { thoughtChoices } from "./thoughtChoices";
import { DisclosureChevron } from "./DisclosureChevron";
/// The reader's open or closed, by thought, so a row the transcript unmounts and mounts again keeps it.
const choices = thoughtChoices;

/// A thought's text as drawn: its headings as muted titles (thoughtParts), one wrapper so the live
/// viewport's column keeps the parts in order.
const ThoughtText = memo(function ThoughtText({ text }: { text: string }) {
  return (
    <span className="cv-thought__parts">
      {thoughtParts(text).map((part, index) =>
        "title" in part ? (
          <span key={index} className="cv-thought__title">
            {part.title}
          </span>
        ) : (
          <span key={index} className="cv-thought__part">
            {part.text}
          </span>
        ),
      )}
    </span>
  );
});

/// A finished thought's folded row, for a thought on its own row and one in an opened group: the brain
/// glyph and the thought's own first line, cut to one line with an ellipsis; opening leaves that line
/// where it is, lets it wrap, and unfolds the rest of the text under it (Leo, 2026-11-22: "what if
/// instead of Thought blah blah we simply... had the whole line be the line? then you expand and it
/// simply shows you the rest. the brain, of course, stays."). No word is swapped, so the change is a
/// morph: the line and the body grow or shrink over the fold's time ("i think we'd likely want a
/// morphing animation to and from thought"). A leading heading is the line; a thought whose line
/// holds all of it opens nothing and draws no chevron; a thought with no words to show reads
/// "Thought". How long it took sits muted at the row's end once it is open or under the pointer.
function FoldedThought({
  text,
  time,
  fold,
  className,
  bodyClassName,
}: {
  text: string;
  /// "12s", when the thought is dated and took a second or more.
  time: string | undefined;
  fold: AnchoredCollapse;
  className: string;
  bodyClassName: string;
}) {
  const t = useT();
  const head = useMemo(() => thoughtHead(text), [text]);
  const bodyId = useId();
  const line = useRef<HTMLSpanElement>(null);
  const { open } = fold;
  // Whether the closed line holds more words than it shows; kept while open (an open line is whole).
  const [cut, setCut] = useState(false);
  // A row that opens is a button and one that does not is not: the line is a new node when that
  // flips, so the watch follows it.
  const opens = head.rest !== "" || cut || open;
  // Read by the ResizeObserver only, never in the commit (Leo, 2026-11-26: "Why should non visible
  // thing even affect the renderer thread anyways?"): a read here forced style and layout on the
  // main thread for every folded row the commit mounted, off-screen ones too (208 ms in a traced
  // replay under load). The observer reports each line once after the frame's own layout, before
  // its paint, where the read costs nothing more; a change it finds renders at once (flushSync),
  // so a cut line draws its chevron in that same first frame. A page with no ResizeObserver reads
  // in the commit, as before.
  useLayoutEffect(() => {
    const node = line.current;
    if (!node || open) return;
    const Observer = node.ownerDocument.defaultView?.ResizeObserver;
    if (!Observer) {
      setCut(thoughtLayout.cut(node));
      return;
    }
    let was: boolean | undefined;
    const observer = new Observer(() => {
      const now = thoughtLayout.cut(node);
      if (now === was) return;
      was = now;
      flushSync(() => setCut(now));
    });
    observer.observe(node);
    return () => observer.disconnect();
  }, [head.line, open, opens]);
  // Closed and cut, the line wraps at a word and shows its first line only, so its box ran past
  // that line's last word and the chevron after it stood 12 to 28px off the words, where every
  // other row's stands --cv-chevron-gap (Leo, 2026-11-25: "chevron spacing bad"). The box takes
  // the first line's own width: the same words on it, broken at the same place, and opened it gets
  // its whole width back, so opening moves none of them. test/transcript-chevron-after-label.test.ts.
  useLayoutEffect(() => {
    const node = line.current;
    if (!node) return;
    if (open || !cut) {
      node.style.maxWidth = "";
      return;
    }
    const fit = () => {
      node.style.maxWidth = "";
      const width = firstLineWidth(node);
      if (width !== null) node.style.maxWidth = `${Math.ceil(width) + 1}px`;
    };
    fit();
    const row = node.parentElement;
    const Observer = node.ownerDocument.defaultView?.ResizeObserver;
    if (!row || !Observer) return;
    let width = row.getBoundingClientRect().width;
    const observer = new Observer(() => {
      const now = row.getBoundingClientRect().width;
      if (now === width) return;
      width = now;
      fit();
    });
    observer.observe(row);
    return () => observer.disconnect();
  }, [head.line, open, cut]);
  // The line's height when the reader clicked, for the morph: only their toggle plays it.
  const from = useRef<number | undefined>(undefined);
  useLayoutEffect(() => {
    const node = line.current;
    const before = from.current;
    from.current = undefined;
    if (!node || before === undefined) return;
    const after = thoughtLayout.height(node);
    if (open) return playResize(node, before, after);
    // Closing: the wrapped words stay until the line is one line tall again, then the ellipsis.
    node.classList.add("is-closing");
    playResize(node, before, after, () => node.classList.remove("is-closing"));
  }, [open]);
  const words = head.line || t("tools.thought");
  const lineClass = `cv-tool__text cv-thought__preview${head.title ? " is-title" : ""}${open ? " is-open" : ""}`;
  // Find counts the thought's words, not how long it took.
  const meta = time && (
    <span className="cv-tool__meta cv-thought__time" data-find-skip>
      {time}
    </span>
  );
  if (!opens)
    return (
      <div className={`${className} is-whole`}>
        <span className="cv-tool__icon">
          <Brain />
        </span>
        <span ref={line} className={`${lineClass} selectable`} dir="auto">
          {words}
        </span>
        {meta}
      </div>
    );
  return (
    <>
      <button
        type="button"
        className={`${className} is-toggle${open ? " is-open" : ""}`}
        aria-expanded={open}
        aria-label={thoughtName(words)}
        aria-controls={open && head.rest ? bodyId : undefined}
        ref={fold.headerRef}
        onClick={(event) => {
          const node = line.current;
          const before = node ? thoughtLayout.height(node) : undefined;
          if (fold.toggle(event)) from.current = before;
        }}
      >
        <span className="cv-tool__icon">
          <Brain />
        </span>
        {/* The body holds the rest of the text, so Find counts the line here. */}
        <span ref={line} className={lineClass} dir="auto">
          {words}
        </span>
        <DisclosureChevron open={open} />
        {meta}
      </button>
      {fold.present && head.rest && (
        <div {...fold.bodyProps}>
          <div
            id={bodyId}
            className={`cv-thought__text cv-thought__body ${bodyClassName}${head.gap ? " is-gap" : ""} selectable`}
            dir="auto"
          >
            <ThoughtText text={head.rest} />
          </div>
        </div>
      )}
    </>
  );
}

/// The width of a wrapped line's first line, from its words' own boxes (null when it draws none).
function firstLineWidth(node: HTMLElement): number | null {
  const range = node.ownerDocument.createRange();
  range.selectNodeContents(node);
  // A DOM with no layout (a unit test's) has no boxes to read.
  if (typeof range.getClientRects !== "function") return null;
  const rects = [...range.getClientRects()].filter((rect) => rect.width > 0);
  const first = rects[0];
  if (!first) return null;
  const line = rects.filter((rect) => Math.abs(rect.top - first.top) < first.height / 2);
  return Math.max(...line.map((rect) => rect.right)) - Math.min(...line.map((rect) => rect.left));
}

/// A finished thought's time for its row's end: "12s" once dated and a second or more, unless the
/// Debug choice `thoughtHeader` is "preview".
function thoughtTime(item: AcpmuxActivity): string | undefined {
  const ms = thoughtLayout.header() === "duration" ? thoughtDuration(item) : undefined;
  return ms !== undefined && ms >= 1000 ? formatDuration(ms) : undefined;
}

/// A thought (the agent's reasoning) on its row. Once done it folds to one quiet line, the brain
/// glyph and its words cut with an ellipsis, that opens to "Thought for 12s" over its text (an
/// undated thought, or one under a second, reads "Thought"), as Codex draws it; a quiet one
/// (thoughts.ts `isQuietThought`) draws nothing. While it streams it reads "Thinking" on its own
/// line with the text under it, never after the label as one sentence (Leo 2026-10-21: "Thought I
/// am here" read weird); one taller than THOUGHT_LIVE_PX holds a fixed viewport that keeps its
/// newest line in view, as Codex's reasoning trace does. Shown in full once done (a Debug choice
/// below), it reads "Thought for 12s" over its text. Headings in the text (Codex's `**Heading**`)
/// draw as titles (thoughtParts). The Debug choice `thoughtFoldThreshold` "viewport" or "codex"
/// folds only a long one, and the choice `thoughtHeader` "preview" opens to "Thought" without its
/// time. The reader's toggle always wins over the fold (`choice ?? !folds`). The fold
/// snaps; the reader's toggle plays the transcript's fold (fold.ts), except under Reduce Motion.
export const ThoughtRow = memo(function ThoughtRow({
  item,
  id,
  streaming = false,
}: {
  item: AcpmuxActivity;
  id?: string;
  streaming?: boolean;
}) {
  const t = useT();
  const text = item.text.trim();
  const threshold = thoughtLayout.threshold();
  const [long, setLong] = useState(false);
  // The chat's transcript view (transcriptView.ts): Thinking and Verbose open every thought. The
  // reader's toggles are kept per view, as the transcript's disclosures are.
  const view = useTranscriptViewContext();
  const choiceKey = id === undefined ? undefined : view === "normal" ? id : `${view}:${id}`;
  const [choice, setChoice] = useState<boolean | undefined>(() => (choiceKey ? choices.get(choiceKey) : undefined));
  const [choiceView, setChoiceView] = useState(view);
  if (choiceView !== view) {
    setChoiceView(view);
    setChoice(choiceKey ? choices.get(choiceKey) : undefined);
  }
  const full = useRef<HTMLSpanElement>(null);
  const toggled = useRef(false);
  const folds = !streaming && (long || threshold === "every");
  const liveViewport = streaming;
  const [tall, setTall] = useState(false);
  const clipped = liveViewport && tall;
  const open = choice ?? (!folds || view !== "normal");
  // Only the reader's toggle plays the fold; the automatic fold, and Find opening it, snap.
  const choose = (next: boolean) => {
    setChoice(next);
    if (choiceKey) choices.set(choiceKey, next);
  };
  const fold = useAnchoredCollapse({
    open,
    onOpenChange: (next) => {
      toggled.current = true;
      choose(next);
    },
    animates: () => toggled.current,
  });
  // Find in Chat opens a folded thought that holds its match.
  useFindReveal(
    useMemo(() => [item], [item]),
    () => {
      if (folds) choose(true);
    },
  );
  // Measured before paint while the text shows, in full or in the live viewport (its whole height,
  // not the clip); a folded thought's text no longer changes.
  useLayoutEffect(() => {
    const node = full.current;
    if (!node) return;
    const drawn = Math.max(thoughtLayout.height(node), thoughtLayout.contentHeight(node));
    // A thought the live viewport clipped folds once done, so nothing grows after it streams.
    setLong(drawn > THOUGHT_LIVE_PX);
    if (liveViewport) setTall(drawn > THOUGHT_LIVE_PX);
  }, [text, liveViewport]);
  // After the fold's own layout effect has read it.
  useLayoutEffect(() => {
    toggled.current = false;
  }, [open]);
  if (!text || (!streaming && isQuietThought(item))) return null;
  const done = (ms: number | undefined) =>
    ms !== undefined && ms >= 1000 ? t("tools.thoughtFor", { time: formatDuration(ms) }) : t("tools.thought");
  // In full: the label on its own line ("Thinking" while it streams, "Thought for 12s" once done),
  // the text under it at the opened fold's indent, so the two never read as one sentence.
  if (!folds)
    return (
      <div className={clipped ? "cv-tool cv-thought is-full is-live" : "cv-tool cv-thought is-full"}>
        <span className={streaming ? "cv-thought__label cv-thinking" : "cv-thought__label"} data-find-skip>
          {streaming ? t("thinking") : done(thoughtDuration(item))}
        </span>
        <span ref={full} className="cv-thought__text selectable" dir="auto">
          <ThoughtText text={text} />
        </span>
      </div>
    );
  return (
    <FoldedThought text={text} time={thoughtTime(item)} fold={fold} className="cv-tool cv-thought" bodyClassName="" />
  );
});

/// A thought as one step of an opened group (ToolGroupRow.tsx). Every one starts closed. The thought
/// that led into the run (`lead`), opened, reads "Thought" or "Thought for 6s" with the disclosure
/// right after the words, its whole text under them, as Claude Code desktop lists a run's (cmux#27896 parked that disclosure at
/// the row's far edge; gallery agent-pane.claude-desktop-organization keeps it as `lead-edge`); closed, its words on one line cut with an ellipsis and
/// the disclosure right after them. A later thought is one quiet row like ThoughtRow's, the brain
/// glyph and its words, that opens to "Thought" or "Thought for 12s" over its whole text
/// (agent-pane-step-rows.test.ts). The reader's choice is kept by `id` with ThoughtRow's,
/// so a thought that drew on its own keeps it once a call joins it to the group. Find in Chat opens
/// one that holds its match.
export function StepThought({ item, id, lead = false }: { item: AcpmuxActivity; id: string; lead?: boolean }) {
  const text = item.text.trim();
  // The reader's choice for this `id` is state, so a click draws again under the React Compiler
  // (a render that only read the kept choices was memoized on `id` and never changed); a row React
  // reuses for another `id` reads that one's kept choice.
  const [chosen, setChosen] = useState<{ id: string; open: boolean } | undefined>(undefined);
  // Closed until the reader opens it, the lead one too: opening or closing a run never opens a thought
  // by itself (Lucas, 2026-11-11), as the Codex app lists a run's thoughts as one line each. Thinking
  // and Verbose, the views for reading the work, open the lead one, as before.
  const view = useTranscriptViewContext();
  const open = chosen?.id === id ? chosen.open : (choices.get(id) ?? (lead && view !== "normal"));
  const choose = (next: boolean) => {
    choices.set(id, next);
    setChosen({ id, open: next });
  };
  useFindReveal(
    useMemo(() => [item], [item]),
    () => choose(true),
  );
  // The reader's click holds the line where it is drawn while the text opens or closes under it, so
  // the same spot closes it again (Lucas, 2026-11-06: the row slid away from the pointer), and the
  // text plays the transcript's fold as every other row's body does.
  const fold = useAnchoredCollapse({ open, onOpenChange: choose });
  return (
    <FoldedThought
      text={text}
      time={thoughtTime(item)}
      fold={fold}
      className={`cv-tool cv-thought cv-step-thought${lead ? " is-lead" : ""}`}
      bodyClassName="cv-step-thought__body"
    />
  );
}
