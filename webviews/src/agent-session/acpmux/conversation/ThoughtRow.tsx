import { useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { AcpmuxActivity } from "../model";
import { useT } from "../i18n";
import { useFindReveal } from "./chatFind";
import { ChevronRight } from "./icons";

/// A done thought folds once it is taller than the transcript's viewport, and never under this
/// (20 of the tool rows' 20px lines), so a small pane does not fold every thought.
export const THOUGHT_FOLD_MIN_PX = 400;
/// How long the reader's open or close takes (AI Elements' Trace: `transition-[height] duration-200`).
export const THOUGHT_FOLD_MS = 200;

/// What the row reads from the page; tests swap these.
export const thoughtLayout = {
  /// The Debug toggle `agentPane.debug.foldLongThoughts` (off by default), which the app sets on
  /// `<html>` as `data-fold-long-thoughts="on"` before the page loads.
  enabled: () => typeof document !== "undefined" && document.documentElement.dataset.foldLongThoughts === "on",
  height: (node: HTMLElement) => node.getBoundingClientRect().height,
  /// The transcript scroller's height (VirtualTranscript's `.acpmux-scroll`).
  viewport: (node: HTMLElement) => node.closest<HTMLElement>(".acpmux-scroll")?.clientHeight ?? 0,
  reducedMotion: () =>
    typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true,
};

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
/// rows' rhythm (Leo 2026-10-13). With the Debug toggle on, a long one shows in full while it
/// streams and folds to one line once done, as Codex folds work when its next output starts; the
/// reader's toggle always wins over the fold (`choice ?? !folds`). The fold snaps; the reader's
/// toggle animates the height, except under Reduce Motion.
export function ThoughtRow({
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
  const [choice, setChoice] = useState<boolean | undefined>(() => (id ? choices.get(id) : undefined));
  const [closing, setClosing] = useState(false);
  const full = useRef<HTMLSpanElement>(null);
  const body = useRef<HTMLDivElement>(null);
  const toggled = useRef(false);
  const bodyId = useId();
  const folds = enabled && long && !streaming;
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
  // Measured as drawn while the text shows in full; a folded thought's text no longer changes.
  useLayoutEffect(() => {
    const node = full.current;
    if (!enabled || !node) return;
    setLong(thoughtLayout.height(node) > Math.max(THOUGHT_FOLD_MIN_PX, thoughtLayout.viewport(node)));
  }, [enabled, text]);
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
      <div className="cv-tool cv-thought">
        <span className="cv-thought__label" data-find-skip>
          {t("tools.thought")}
        </span>
        <span ref={full} className="cv-thought__text selectable" dir="auto">
          {text}
        </span>
      </div>
    );
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
          {t("tools.thought")}
        </span>
        {!open && (
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
