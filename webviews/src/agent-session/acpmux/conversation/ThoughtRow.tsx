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
  return (
    <>
      <button
        type="button"
        className="cv-tool cv-thought is-toggle"
        aria-expanded={open}
        aria-controls={open ? body : undefined}
        onClick={() => setOpen((value) => !value)}
      >
        <span className="cv-tool__text">
          <span className="cv-thought__label">{t("tools.thought")}</span>
          {/* The open text repeats this line, so Find counts it there. */}
          <span className="cv-thought__title" data-find-skip={open || undefined}>
            {firstLine(item.text)}
          </span>
        </span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      {open && (
        <div id={body} className="cv-thought__body selectable">
          {item.text.trim()}
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
