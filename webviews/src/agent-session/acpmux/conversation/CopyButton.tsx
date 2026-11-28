// The copy button in a code card's or tool output's corner. It says "Copied", with a check, only
// when the clipboard took the text, and goes back to Copy after a moment.
import { useEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import { copyTextResult } from "./clipboard";
import { Check, Copy } from "./icons";

/// How long a copy shows its check.
const COPIED_MS = 1200;

export function CopyButton({
  text,
  label,
  className = "cv-codeblock__action",
}: {
  text: string;
  label: string;
  className?: string;
}) {
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
      onClick={async () => {
        const done = await copyTextResult(text);
        window.clearTimeout(timer.current);
        setCopied(done);
        if (done) timer.current = window.setTimeout(() => setCopied(false), COPIED_MS);
      }}
    >
      {copied ? <Check /> : <Copy />}
    </button>
  );
}
