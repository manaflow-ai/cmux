import { memo, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { AcpmuxActivity } from "../model";
import { useT } from "../i18n";
import { useFindReveal } from "./chatFind";
import { ChevronRight } from "./icons";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { useTranscriptViewContext } from "./transcriptDisclosure";
import { formatDuration } from "./turns";
import { isQuietThought, thoughtDuration, thoughtParts } from "./thoughts";

export { thoughtDuration, thoughtParts };

/// With the Debug choice "viewport" and the live viewport off, a done thought folds once it is
/// taller than the transcript's viewport, and never under this (20 of the tool rows' 20px lines).
/// With the live viewport on, or the Debug choice "codex", it folds once taller than
/// THOUGHT_LIVE_PX. By default ("every") every done thought folds.
export const THOUGHT_FOLD_MIN_PX = 400;
/// A long thought still streaming holds a viewport this tall: seven of its 20px lines, the 8.75rem
/// Codex gives a live reasoning trace. conversation.css caps `.is-live` at the same.
export const THOUGHT_LIVE_PX = 140;

/// What the row reads from the page; tests swap these.
export const thoughtLayout = {
  /// The Debug toggle `agentPane.debug.foldLongThoughts` (on by default): thoughts fold unless the
  /// app sets `data-fold-long-thoughts="off"` on `<html>` before the page loads.
  enabled: () => typeof document === "undefined" || document.documentElement.dataset.foldLongThoughts !== "off",
  /// The Debug choice `agentPane.debug.thoughtFoldThreshold`: by default ("every") every done
  /// thought folds. `data-thought-fold-threshold="viewport"` or `"codex"` brings back the older
  /// fold of long thoughts only, a short one in full after "Thought": with the live viewport on,
  /// once taller than Codex's seven lines (THOUGHT_LIVE_PX); with it off, once taller than the
  /// transcript's viewport (never under THOUGHT_FOLD_MIN_PX), or with "codex", than seven lines.
  threshold: (): ThoughtFoldThreshold => {
    const value = typeof document === "undefined" ? undefined : document.documentElement.dataset.thoughtFoldThreshold;
    return value === "viewport" || value === "codex" ? value : "every";
  },
  /// The Debug choice `agentPane.debug.thoughtHeader`: a folded thought reads "Thought for 12s"
  /// unless the app sets `data-thought-header="preview"`, "Thought" and its first line (#20948).
  header: (): ThoughtHeader =>
    typeof document !== "undefined" && document.documentElement.dataset.thoughtHeader === "preview"
      ? "preview"
      : "duration",
  /// The Debug toggle `agentPane.debug.liveThoughtViewport` (on by default): a long thought streams
  /// in a fixed viewport unless the app sets `data-live-thought-viewport="off"`.
  liveViewport: () => typeof document === "undefined" || document.documentElement.dataset.liveThoughtViewport !== "off",
  height: (node: HTMLElement) => node.getBoundingClientRect().height,
  /// The text's whole height, also while the live viewport clips it.
  contentHeight: (node: HTMLElement) => node.scrollHeight,
  /// The transcript scroller's height (VirtualTranscript's `.acpmux-scroll`).
  viewport: (node: HTMLElement) => node.closest<HTMLElement>(".acpmux-scroll")?.clientHeight ?? 0,
};

export type ThoughtHeader = "duration" | "preview";
export type ThoughtFoldThreshold = "every" | "viewport" | "codex";

/// The reader's open or closed, by thought, so a row the transcript unmounts and mounts again keeps it.
const choices = new Map<string, boolean>();

/// The folded line's text: the thought's first line without Codex's heading marks (`#`, `**`).
export function thoughtPreview(text: string): string {
  return (text.split("\n", 1)[0] ?? "")
    .replace(/^#+\s*/, "")
    .replace(/\*\*/g, "")
    .trim();
}

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

/// A thought (the agent's reasoning) on its row. Once done it folds to one quiet line that opens to
/// its text, "Thought for 12s" with none of the text inline (an undated thought, or one under a
/// second, reads "Thought"), as Claude Desktop and Codex draw it (Leo 2026-10-20); a quiet one
/// (thoughts.ts `isQuietThought`) draws nothing. While it streams it reads "Thinking" on its own
/// line with the text under it, never after the label as one sentence (Leo 2026-10-21: "Thought I
/// am here" read weird); one taller than THOUGHT_LIVE_PX holds a fixed viewport that keeps its
/// newest line in view, as Codex's reasoning trace does (Debug toggle `liveThoughtViewport`; off,
/// it shows in full). Shown in full once done (a Debug choice below), it reads "Thought for 12s"
/// over its text. Headings in the text (Codex's `**Heading**`) draw as titles (thoughtParts). The
/// Debug choice `thoughtFoldThreshold` "viewport" or "codex" folds only a long one, the toggle
/// `foldLongThoughts` off folds none, and the choice `thoughtHeader` "preview" reads "Thought" and
/// its first line. The reader's toggle always wins over the fold (`choice ?? !folds`). The fold
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
  const enabled = thoughtLayout.enabled();
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
  const folds = enabled && !streaming && (long || thoughtLayout.threshold() === "every");
  const liveViewport = enabled && streaming && thoughtLayout.liveViewport();
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
    if (!enabled || !node) return;
    const drawn = Math.max(thoughtLayout.height(node), thoughtLayout.contentHeight(node));
    // While the live viewport is on, a thought it clipped folds once done, so nothing grows after
    // it streams; otherwise the threshold choice decides.
    const limit =
      thoughtLayout.liveViewport() || thoughtLayout.threshold() === "codex"
        ? THOUGHT_LIVE_PX
        : Math.max(THOUGHT_FOLD_MIN_PX, thoughtLayout.viewport(node));
    setLong(drawn > limit);
    if (liveViewport) setTall(drawn > THOUGHT_LIVE_PX);
  }, [enabled, text, liveViewport]);
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
        <span className="cv-thought__label" data-find-skip>
          {label}
        </span>
        {!open && header === "preview" && (
          <span className="cv-tool__text cv-thought__preview" dir="auto" data-find-skip>
            {thoughtPreview(text)}
          </span>
        )}
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
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

/// A thought as one step of an opened group (ToolGroupRow.tsx). The thought that led into the run
/// (`lead`) starts open, its whole text in that place with the disclosure at the top of the row's
/// end, as Claude Code desktop lists a run's; closed, its words on one line cut with an ellipsis and
/// the disclosure right after them. A later thought is one quiet row like ThoughtRow's, "Thought" or
/// "Thought for 12s" with none of its text inline, that opens to its whole text under it (Leo
/// 2026-10-20, agent-pane-step-rows.test.ts). The reader's choice is kept by `id` with ThoughtRow's,
/// so a thought that drew on its own keeps it once a call joins it to the group. Find in Chat opens
/// one that holds its match.
export function StepThought({ item, id, lead = false }: { item: AcpmuxActivity; id: string; lead?: boolean }) {
  const t = useT();
  const text = item.text.trim();
  // The reader's choice for this `id` is state, so a click draws again under the React Compiler
  // (a render that only read the kept choices was memoized on `id` and never changed); a row React
  // reuses for another `id` reads that one's kept choice.
  const [chosen, setChosen] = useState<{ id: string; open: boolean } | undefined>(undefined);
  const open = chosen?.id === id ? chosen.open : (choices.get(id) ?? lead);
  const bodyId = useId();
  const choose = (next: boolean) => {
    choices.set(id, next);
    setChosen({ id, open: next });
  };
  useFindReveal(
    useMemo(() => [item], [item]),
    () => choose(true),
  );
  // One line of its words, its headings' marks left out (thoughtPreview), its breaks as spaces.
  const line = useMemo(
    () => (open || !lead ? "" : text.split("\n").map(thoughtPreview).filter(Boolean).join(" ")),
    [open, lead, text],
  );
  // A later thought's quiet label, as ThoughtRow's folded line reads.
  const ms = lead || thoughtLayout.header() !== "duration" ? undefined : thoughtDuration(item);
  const label =
    ms !== undefined && ms >= 1000 ? t("tools.thoughtFor", { time: formatDuration(ms) }) : t("tools.thought");
  return (
    <>
      <button
        type="button"
        className={`cv-tool is-toggle cv-thought cv-step-thought${open && lead ? " is-open" : ""}`}
        aria-expanded={open}
        aria-controls={open ? bodyId : undefined}
        aria-label={open && lead ? t("tools.thought") : undefined}
        onClick={() => choose(!open)}
      >
        {!lead ? (
          <span className="cv-tool__text cv-thought__label" data-find-skip>
            {label}
          </span>
        ) : (
          !open && (
            <span className="cv-tool__text cv-thought__preview" dir="auto" data-find-skip>
              {line}
            </span>
          )
        )}
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      {open && (
        <div id={bodyId} className="cv-thought__text cv-thought__body cv-step-thought__body selectable" dir="auto">
          <ThoughtText text={text} />
        </div>
      )}
    </>
  );
}
