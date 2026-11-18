"use client";

import { useEffect, useState } from "react";

const COPIED_MS = 1800;

/** A one-line snippet (README badge, install command) with a Copy button; long tokens wrap anywhere. */
export function CopySnippet({ text, copyLabel, copiedLabel }: { text: string; copyLabel: string; copiedLabel: string }) {
  const [copied, setCopied] = useState(false);

  // "Copied" reverts after a moment; the effect owns the timer and clears it on unmount or a new copy.
  useEffect(() => {
    if (!copied) return;
    const timer = window.setTimeout(() => setCopied(false), COPIED_MS);
    return () => window.clearTimeout(timer);
  }, [copied]);

  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  }

  return (
    <div className="flex items-start gap-2 rounded-lg border border-border bg-code-bg py-2.5 pl-3 pr-2">
      <code className="min-w-0 flex-1 break-all font-mono text-[12px] leading-5 text-foreground">{text}</code>
      <button
        type="button"
        onClick={copy}
        aria-label={copied ? copiedLabel : copyLabel}
        className="shrink-0 rounded-md border border-border bg-background px-2 py-0.5 text-[12px] text-muted transition-colors hover:text-foreground"
      >
        {copied ? copiedLabel : copyLabel}
      </button>
    </div>
  );
}
