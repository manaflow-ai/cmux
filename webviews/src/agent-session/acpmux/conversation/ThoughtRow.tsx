import { useId, useMemo, useState } from "react";
import type { AcpmuxActivity } from "../model";
import { useT } from "../i18n";
import { useFindReveal } from "./chatFind";
import { ChevronRight } from "./icons";

/// A thought (the agent's reasoning) as one closed row titled by its first line, kept out of the
/// way as the Codex app does (cx-ncc.73); it opens to the full text. A streaming thought grows in
/// place behind its one-line title, so the transcript does not jump.
export function ThoughtRow({ item }: { item: AcpmuxActivity }) {
  const t = useT();
  const [open, setOpen] = useState(false);
  useFindReveal(
    useMemo(() => [item], [item]),
    () => setOpen(true),
  );
  const body = useId();
  const text = item.text.trim();
  if (!text) return null;
  return (
    <>
      <button
        type="button"
        className="cv-tool cv-thought is-toggle"
        aria-expanded={open}
        aria-controls={open ? body : undefined}
        onClick={() => setOpen((value) => !value)}
      >
        {/* Find counts the thought's text only: the label is the row's, and the open text repeats
            the title, so only the closed title is drawn. */}
        <span className="cv-tool__text">
          <span className="cv-thought__label" data-find-skip>
            {t("tools.thought")}
          </span>
          {!open && (
            <span className="cv-thought__title" dir="auto">
              {firstLine(text)}
            </span>
          )}
        </span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      {open && (
        <div id={body} className="cv-thought__body selectable" dir="auto">
          {text}
        </div>
      )}
    </>
  );
}

const firstLine = (text: string) =>
  text
    .split("\n")
    .map((line) => line.trim())
    .find(Boolean) ?? "";
