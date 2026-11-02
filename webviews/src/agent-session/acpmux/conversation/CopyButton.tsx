// The copy button in a code card's or tool output's corner, and under a prompt or a turn. It says
// "Copied", with a check, only when the clipboard took the text, and goes back to Copy after a
// moment. Its name is also its tooltip: a bare copy glyph does not say what it copies.
import { useEffect, useRef, useState } from "react";
import type { rovingTabStopProps } from "../../../ui/listRowKeyboard";
import { useT } from "../i18n";
import { copyTextResult } from "./clipboard";
import { Check, Copy } from "./icons";

/// How long a copy shows its check.
export const COPIED_MS = 1200;

export function CopyButton({
  text,
  label,
  className = "cv-codeblock__action",
  copy = copyTextResult,
  size,
  copiedWord = false,
  ...tabStop
}: {
  text: string;
  label: string;
  className?: string;
  /** Puts `text` on the clipboard; a table's also adds its other formats (tableFormats.ts). */
  copy?: (text: string) => Promise<boolean>;
  /** The glyph's size; the icons' default when unset. */
  size?: number;
  /** Show the word "Copied" beside the check while it shows (a card corner's look, CardCopy.tsx). */
  copiedWord?: boolean;
} & Partial<ReturnType<typeof rovingTabStopProps>>) {
  const t = useT();
  const [copied, setCopied] = useState(false);
  const timer = useRef<number | undefined>(undefined);
  useEffect(() => () => window.clearTimeout(timer.current), []);
  const name = copied ? t("code.copied") : label;
  return (
    <button
      type="button"
      className={className}
      aria-label={name}
      title={name}
      /* A transcript row's roving tab stop and its keys, from src/ui (rovingTabStopProps). */
      {...tabStop}
      data-copied={copied || undefined}
      onClick={async () => {
        const done = await copy(text);
        window.clearTimeout(timer.current);
        setCopied(done);
        if (done) timer.current = window.setTimeout(() => setCopied(false), COPIED_MS);
      }}
    >
      {copied ? <Check size={size} /> : <Copy size={size} />}
      {copied && copiedWord && <span className="cv-copy__word">{name}</span>}
    </button>
  );
}
