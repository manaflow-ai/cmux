"use client";

import { useState } from "react";

export function CopyPrompt({
  prompt,
  copyLabel,
  copiedLabel,
}: {
  prompt: string;
  copyLabel: string;
  copiedLabel: string;
}) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(prompt);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1800);
    } catch {
      setCopied(false);
    }
  }

  return (
    <div className="not-prose relative rounded-lg border border-border bg-code-bg px-4 py-3">
      <pre className="m-0 whitespace-pre-wrap pr-20 font-mono text-[13px] leading-relaxed text-foreground">
        {prompt}
      </pre>
      <button
        type="button"
        onClick={copy}
        className="absolute right-3 top-3 rounded-md border border-border px-2.5 py-1 text-xs text-muted transition-colors hover:bg-background hover:text-foreground"
      >
        {copied ? copiedLabel : copyLabel}
      </button>
    </div>
  );
}
