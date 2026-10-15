import { useId, useMemo, useState } from "react";
import type { AcpmuxActivity } from "../model";
import { useT } from "../i18n";
import { useFindReveal } from "./chatFind";
import { ChevronRight } from "./icons";
import { formatDuration } from "./turns";

/// A thought (the agent's reasoning) as Codex and Claude desktop draw one (Leo 2026-10-13): one
/// muted, closed "Thought for 4s" line that opens to the whole text. The thought the agent is
/// still writing reads "Thinking…". `until` is when the next entry started: the thought lasted
/// from its first chunk to then, or to its latest chunk when nothing followed.
export function ThoughtRow({ item, until, live }: { item: AcpmuxActivity; until?: number; live?: boolean }) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const textId = useId();
  // Find in Chat opens a thought that holds its match.
  useFindReveal(
    useMemo(() => [item], [item]),
    () => setOpen(true),
  );
  const text = item.text.trim();
  if (!text) return null;
  const end = until ?? item.endedAt;
  const label = live
    ? t("tools.thinking")
    : item.startedAt !== undefined && end !== undefined
      ? t("tools.thoughtFor", { time: formatDuration(Math.max(0, end - item.startedAt)) })
      : t("tools.thought");
  return (
    <>
      <button
        type="button"
        className={`cv-tool is-toggle cv-thought${live ? " is-live" : ""}`}
        aria-expanded={open}
        aria-controls={open ? textId : undefined}
        onClick={() => setOpen((value) => !value)}
      >
        {/* Find counts the thought's text, not this line's words. */}
        <span className="cv-thought__label" data-find-skip>
          {label}
        </span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      {open && (
        <div id={textId} className="cv-thought__text selectable" dir="auto">
          {text}
        </div>
      )}
    </>
  );
}
