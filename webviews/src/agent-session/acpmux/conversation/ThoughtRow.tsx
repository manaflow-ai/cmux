import { useId, useLayoutEffect, useRef, useState } from "react";
import type { AcpmuxActivity } from "../model";
import { useT } from "../i18n";
import { useFindReveal } from "./chatFind";
import { ChevronRight } from "./icons";
import { formatDuration } from "./turns";

/// A thought taller than this folds: seven of its 20px lines, the 8.75rem Codex gives a reasoning
/// trace (briefs/codex-reasoning-collapse.md). conversation.css caps the live viewport at the same.
export const THOUGHT_FOLD_PX = 140;

/// Thoughts the reader opened, by row and place, so one stays open when the transcript draws its
/// row again (scrolled away and back, or copied under "Worked for" when the turn ends).
const opened = new Set<string>();

/// A thought (the agent's reasoning) on its row: a muted "Thought", then its text wrapped on the
/// tool rows' rhythm (Leo 2026-10-13). A short thought always shows in full. A long one folds the
/// way Codex's reasoning trace does (Leo 2026-10-15): while the agent is still thinking it, it
/// reads "Thinking" and streams in a fixed viewport that keeps its newest line in view; once it
/// ends, it folds to one line, "Thought for 12s", that opens on a click or Enter.
export function ThoughtRow({
  item,
  streaming = false,
  openKey,
}: {
  item: AcpmuxActivity;
  streaming?: boolean;
  openKey?: string;
}) {
  const t = useT();
  const text = item.text.trim();
  const textRef = useRef<HTMLSpanElement>(null);
  // Measured before paint, so a long thought never draws its full height first.
  const [long, setLong] = useState(false);
  const [open, setOpenState] = useState(() => (openKey ? opened.has(openKey) : false));
  const setOpen = (next: boolean) => {
    if (openKey && next) opened.add(openKey);
    else if (openKey) opened.delete(openKey);
    setOpenState(next);
  };
  const body = useId();
  // Find opens a folded thought that holds its match (chatFind.ts).
  useFindReveal([item], () => setOpen(true));
  useLayoutEffect(() => {
    // A thought's text only grows, so one that folded stays folded.
    if (long) return;
    const element = textRef.current;
    if (element && element.scrollHeight > THOUGHT_FOLD_PX) setLong(true);
  }, [long, text]);
  if (!text) return null;

  if (long && !streaming) {
    const ms = item.startedAt !== undefined && item.endedAt !== undefined ? item.endedAt - item.startedAt : 0;
    return (
      <div className="cv-thought cv-thought-fold">
        <button
          type="button"
          className="cv-tool is-toggle"
          aria-expanded={open}
          aria-controls={open ? body : undefined}
          onClick={() => setOpen(!open)}
        >
          <span className="cv-tool__text" data-find-skip>
            {ms >= 1000 ? t("tools.thoughtFor", { time: formatDuration(ms) }) : t("tools.thought")}
          </span>
          <ChevronRight
            size={14}
            strokeWidth={1.2}
            className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
          />
        </button>
        {open && (
          <div id={body} className="cv-thought__body cv-enter selectable" dir="auto">
            {text}
          </div>
        )}
      </div>
    );
  }

  return (
    <div className={long ? "cv-tool cv-thought is-live" : "cv-tool cv-thought"}>
      <span className={long ? "cv-thought__label cv-thinking" : "cv-thought__label"} data-find-skip>
        {long ? t("thinking") : t("tools.thought")}
      </span>
      <span className="cv-thought__text selectable" dir="auto" ref={textRef}>
        {text}
      </span>
    </div>
  );
}
