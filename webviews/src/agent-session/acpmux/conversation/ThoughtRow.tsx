import { useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { AcpmuxActivity } from "../model";
import { useT } from "../i18n";
import { useFindReveal } from "./chatFind";
import { ChevronRight } from "./icons";
import { ThoughtFold } from "./ThoughtFold";
import { thoughtStyle } from "./thoughtStyle";
import { formatDuration } from "./turns";

/// With the live viewport off, a done thought folds once it is taller than the transcript's
/// viewport, and never under this (20 of the tool rows' 20px lines), so a small pane does not fold
/// every thought. With the live viewport on, or the Debug choice "codex", it folds once taller
/// than THOUGHT_LIVE_PX.
export const THOUGHT_FOLD_MIN_PX = 400;
/// A long thought still streaming holds a viewport this tall: seven of its 20px lines, the 8.75rem
/// Codex gives a live reasoning trace. conversation.css caps `.is-live` at the same.
export const THOUGHT_LIVE_PX = 140;
/// How long the reader's open or close takes (AI Elements' Trace: `transition-[height] duration-200`).
export const THOUGHT_FOLD_MS = 200;

/// What the row reads from the page; tests swap these.
export const thoughtLayout = {
  /// The Debug toggle `agentPane.debug.foldLongThoughts` (on by default in the app), which the app
  /// sets on `<html>` as `data-fold-long-thoughts="on"` before the page loads.
  enabled: () => typeof document !== "undefined" && document.documentElement.dataset.foldLongThoughts === "on",
  /// The Debug choice `agentPane.debug.thoughtFoldThreshold`, which counts only while the live
  /// viewport is off: a done thought folds once taller than the transcript's viewport (never under
  /// THOUGHT_FOLD_MIN_PX), or with `data-thought-fold-threshold="codex"`, once taller than Codex's
  /// seven lines (THOUGHT_LIVE_PX).
  threshold: (): ThoughtFoldThreshold =>
    typeof document !== "undefined" && document.documentElement.dataset.thoughtFoldThreshold === "codex"
      ? "codex"
      : "viewport",
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
  reducedMotion: () =>
    typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true,
};

export type ThoughtHeader = "duration" | "preview";
export type ThoughtFoldThreshold = "viewport" | "codex";

/// How long the agent thought, from the thought's first chunk to its latest (direct.ts
/// appendThought), never negative: events out of order can date the latest before the first.
export function thoughtDuration(item: AcpmuxActivity): number | undefined {
  if (item.startedAt === undefined || item.endedAt === undefined) return undefined;
  return Math.max(0, item.endedAt - item.startedAt);
}

/// The reader's open or closed, by thought, so a row the transcript unmounts and mounts again keeps it.
const choices = new Map<string, boolean>();

/// The folded line's text: the thought's first line without Codex's heading marks (`#`, `**`).
export function thoughtPreview(text: string): string {
  return (text.split("\n", 1)[0] ?? "")
    .replace(/^#+\s*/, "")
    .replace(/\*\*/g, "")
    .trim();
}

/// A thought (the agent's reasoning) on its row: a muted "Thought", then the text wrapped on the tool
/// rows' rhythm (Leo 2026-10-13). With the Debug toggle on, a long one folds to one line once done,
/// as Codex folds work when its next output starts. While it streams, one taller than
/// THOUGHT_LIVE_PX reads "Thinking" and holds a fixed viewport that keeps its newest line in view,
/// as Codex's reasoning trace does (Debug toggle `liveThoughtViewport`; off, it shows in full). The
/// folded line reads "Thought for 12s" (an undated thought, or one under a second, reads
/// "Thought"), or with the Debug choice "preview", "Thought" and its first line. The reader's
/// toggle always wins over the fold (`choice ?? !folds`). The fold snaps; the reader's toggle
/// animates the height, except under Reduce Motion.
export function ThoughtRow(props: { item: AcpmuxActivity; id?: string; streaming?: boolean }) {
  // The Debug choice agentPane.debug.thoughtStyle (thoughtStyle.ts): a brain line that opens.
  if (thoughtStyle.current() === "brain")
    return <ThoughtFold id={props.id} text={props.item.text.trim()} streaming={props.streaming} />;
  return <PlainThoughtRow {...props} />;
}

function PlainThoughtRow({ item, id, streaming = false }: { item: AcpmuxActivity; id?: string; streaming?: boolean }) {
  const t = useT();
  const text = item.text.trim();
  const enabled = thoughtLayout.enabled();
  const [long, setLong] = useState(false);
  const [choice, setChoice] = useState<boolean | undefined>(() => (id ? choices.get(id) : undefined));
  const [closing, setClosing] = useState(false);
  const full = useRef<HTMLSpanElement>(null);
  const body = useRef<HTMLDivElement>(null);
  const toggled = useRef(false);
  const bodyId = useId();
  const folds = enabled && long && !streaming;
  const liveViewport = enabled && streaming && thoughtLayout.liveViewport();
  const [tall, setTall] = useState(false);
  const clipped = liveViewport && tall;
  const open = choice ?? !folds;
  const choose = (next: boolean) => {
    setChoice(next);
    if (id) choices.set(id, next);
  };
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
  useLayoutEffect(() => {
    if (!toggled.current) return;
    toggled.current = false;
    const node = body.current;
    if (!node || typeof node.animate !== "function" || thoughtLayout.reducedMotion()) {
      setClosing(false);
      return;
    }
    for (const running of node.getAnimations?.() ?? []) running.cancel();
    const height = `${node.scrollHeight}px`;
    const animation = node.animate(open ? [{ height: "0px" }, { height }] : [{ height }, { height: "0px" }], {
      duration: THOUGHT_FOLD_MS,
      easing: "ease-out",
    });
    if (!open) animation.onfinish = () => setClosing(false);
  }, [open]);
  if (!text) return null;
  if (!folds)
    return (
      <div className={clipped ? "cv-tool cv-thought is-live" : "cv-tool cv-thought"}>
        <span className={clipped ? "cv-thought__label cv-thinking" : "cv-thought__label"} data-find-skip>
          {clipped ? t("thinking") : t("tools.thought")}
        </span>
        <span ref={full} className="cv-thought__text selectable" dir="auto">
          {text}
        </span>
      </div>
    );
  const header = thoughtLayout.header();
  const ms = header === "duration" ? thoughtDuration(item) : undefined;
  const label =
    ms !== undefined && ms >= 1000 ? t("tools.thoughtFor", { time: formatDuration(ms) }) : t("tools.thought");
  const toggle = () => {
    toggled.current = true;
    if (open && !thoughtLayout.reducedMotion()) setClosing(true);
    choose(!open);
  };
  return (
    <>
      <button
        type="button"
        className="cv-tool is-toggle cv-thought"
        aria-expanded={open}
        aria-controls={open ? bodyId : undefined}
        onClick={toggle}
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
      {(open || closing) && (
        <div ref={body} id={bodyId} className="cv-thought__text cv-thought__body selectable" dir="auto">
          {text}
        </div>
      )}
    </>
  );
}
