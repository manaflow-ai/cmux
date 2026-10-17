// A thought as one quiet line (thoughtStyle.ts `brain`): a brain, then what the agent was
// thinking in the tool rows' muted color; opened, a muted "Thoughts" over the whole text in the
// transcript's own color, under a left rule, so the reasoning reads as a layer below the answer
// (Lucas 2026-10-17).
import { useId, useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { useFindReveal } from "./chatFind";
import { Brain, ChevronRight } from "./icons";
import { RevealedMarkdown } from "./RevealedMarkdown";

/// The reader's open or closed, by thought, so a row the transcript unmounts and mounts again keeps it.
const opened = new Map<string, boolean>();

/// The line's text: the first line with words in it, without Markdown's marks (headings, bold,
/// code ticks) or a code fence.
export function thoughtLine(text: string): string {
  for (const line of text.split("\n")) {
    if (/^\s*(```|~~~)/.test(line)) continue;
    const plain = line
      .replace(/^\s*(#+|[-*+]|\d+[.)]|>)\s+/, "")
      .replace(/\*\*|__|`/g, "")
      .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
      .trim();
    if (plain) return plain;
  }
  return "";
}

export function ThoughtFold({
  id,
  text,
  streaming = false,
  githubRepository,
}: {
  id?: string;
  text: string;
  streaming?: boolean;
  githubRepository?: string;
}) {
  const t = useT();
  const [open, setOpen] = useState(() => (id ? opened.get(id) : undefined) ?? false);
  const choose = (next: boolean) => {
    setOpen(next);
    if (id) opened.set(id, next);
  };
  // Find in Chat opens a closed thought that holds its match.
  const items: AcpmuxActivity[] = [{ kind: "thought", text }];
  useFindReveal(items, () => choose(true));
  const body = useId();
  const line = thoughtLine(text);
  if (!line) return null;
  return (
    <>
      <button
        type="button"
        className={`cv-tool is-toggle is-strong cv-thought-fold${streaming ? " is-streaming" : ""}`}
        aria-expanded={open}
        aria-controls={open ? body : undefined}
        onClick={() => choose(!open)}
      >
        <span className="cv-tool__icon">
          <Brain />
        </span>
        <span className="cv-tool__text cv-thought-fold__line" dir="auto" data-find-skip>
          {open ? t("tools.thoughts") : line}
        </span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      {open && (
        <div id={body} className="cv-thought-fold__body selectable" dir="auto">
          <RevealedMarkdown text={text} streaming={streaming} githubRepository={githubRepository} />
        </div>
      )}
    </>
  );
}
