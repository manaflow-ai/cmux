import { memo, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { AcpmuxActivity } from "../model";
import { useT } from "../i18n";
import { useFindReveal } from "./chatFind";
import { Brain, ChevronRight } from "./icons";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { useTranscriptViewContext } from "./transcriptDisclosureModel";
import { formatDuration } from "./turns";
import { isQuietThought, thoughtDuration, thoughtParts } from "./thoughts";
import { THOUGHT_LIVE_PX, thoughtLayout, thoughtLine } from "./thoughtRowModel";
import { thoughtChoices } from "./thoughtChoices";
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
  const bodyId = useId();
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
  const header = thoughtLayout.header();
  const label = done(header === "duration" ? thoughtDuration(item) : undefined);
  return (
    <>
      <button
        type="button"
        className="cv-tool is-toggle cv-thought"
        aria-expanded={open}
        aria-controls={open ? bodyId : undefined}
        ref={fold.headerRef}
        onClick={fold.toggle}
      >
        {/* Codex parity (Lucas, 2026-11-06): the brain glyph on the tools' icon column, the
            thought's own words on one line while closed, "Thought for 12s" once opened over them. */}
        <span className="cv-tool__icon">
          <Brain />
        </span>
        {open ? (
          <span className="cv-tool__text cv-thought__label" data-find-skip>
            {label}
          </span>
        ) : (
          <span className="cv-tool__text cv-thought__preview" dir="auto" data-find-skip>
            {thoughtLine(text)}
          </span>
        )}
        <ChevronRight size={14} className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`} />
      </button>
      {fold.present && (
        <div {...fold.bodyProps}>
          <div id={bodyId} className="cv-thought__text cv-thought__body selectable" dir="auto">
            <ThoughtText text={text} />
          </div>
        </div>
      )}
    </>
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
  const t = useT();
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
  const bodyId = useId();
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
  // One line of its words, its headings' marks left out (thoughtPreview), its breaks as spaces.
  const line = useMemo(() => (open ? "" : thoughtLine(text)), [open, text]);
  // A later thought's quiet label, as ThoughtRow's folded line reads; an opened lead thought reads
  // the same, "Thought for 6s", with its chevron right after the words (design/chat-transcript.md,
  // the chevron after its label), never parked at the row's far edge.
  const ms = thoughtLayout.header() !== "duration" ? undefined : thoughtDuration(item);
  const label =
    ms !== undefined && ms >= 1000 ? t("tools.thoughtFor", { time: formatDuration(ms) }) : t("tools.thought");
  return (
    <>
      <button
        type="button"
        className={`cv-tool is-toggle cv-thought cv-step-thought${open && lead ? " is-open" : ""}`}
        aria-expanded={open}
        aria-controls={open ? bodyId : undefined}
        aria-label={open && lead ? label : undefined}
        ref={fold.headerRef}
        onClick={fold.toggle}
      >
        {/* The brain glyph and the thought's words while closed, as ThoughtRow's. */}
        <span className="cv-tool__icon">
          <Brain />
        </span>
        {open ? (
          <span className="cv-tool__text cv-thought__label" data-find-skip>
            {label}
          </span>
        ) : (
          <span className="cv-tool__text cv-thought__preview" dir="auto" data-find-skip>
            {line}
          </span>
        )}
        <ChevronRight size={14} className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`} />
      </button>
      {fold.present && (
        <div {...fold.bodyProps}>
          <div id={bodyId} className="cv-thought__text cv-thought__body cv-step-thought__body selectable" dir="auto">
            <ThoughtText text={text} />
          </div>
        </div>
      )}
    </>
  );
}
