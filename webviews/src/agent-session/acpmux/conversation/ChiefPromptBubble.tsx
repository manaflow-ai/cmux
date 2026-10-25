import { useState } from "react";
import { useT } from "../i18n";

/// More than this many lines, or characters, and a Chief prompt opens collapsed.
const COLLAPSED_LINES = 6;
const COLLAPSED_CHARS = 600;

/// Whether a prompt is long enough to open collapsed.
export const isLongPrompt = (text: string) =>
  text.length > COLLAPSED_CHARS || text.split("\n").length > COLLAPSED_LINES;

/// A prompt the Chief sent a subagent (its task, a tell, a restart message): marked "From the
/// Chief" so it does not read as the person's own, and a long task shows its first lines with
/// Show all (the session keeps the whole text; copy and select still take all of it when open).
export function ChiefPromptBubble({ text }: { text: string }) {
  const t = useT();
  const long = isLongPrompt(text);
  const [open, setOpen] = useState(false);
  const collapsed = long && !open;
  return (
    <>
      <div className="cv-user__from">{t("transcript.fromChief")}</div>
      <div
        className={
          collapsed
            ? "ui-glass cv-user__bubble cv-user__bubble--collapsed selectable"
            : "ui-glass cv-user__bubble selectable"
        }
      >
        {text}
      </div>
      {long && (
        <button type="button" className="cv-user__expand" aria-expanded={open} onClick={() => setOpen(!open)}>
          {open ? t("transcript.promptShowLess") : t("transcript.promptShowAll")}
        </button>
      )}
    </>
  );
}
