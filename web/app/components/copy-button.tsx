"use client";

import { useState } from "react";

export function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);

  return (
    <button
      type="button"
      onClick={() => {
        navigator.clipboard.writeText(text);
        setCopied(true);
        setTimeout(() => setCopied(false), 2000);
      }}
      className="absolute top-2 right-2 px-2 py-1 text-[11px] font-mono text-muted hover:text-foreground bg-code-bg border border-border rounded transition-colors"
    >
      {copied ? "Copied" : "Copy"}
    </button>
  );
}
