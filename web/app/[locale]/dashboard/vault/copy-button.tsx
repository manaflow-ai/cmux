"use client";

import { useState } from "react";

export function CopyButton({
  value,
  label,
  copiedLabel,
}: {
  readonly value: string;
  readonly label: string;
  readonly copiedLabel: string;
}) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      type="button"
      onClick={() => {
        void navigator.clipboard.writeText(value);
        setCopied(true);
      }}
      className="border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
    >
      {copied ? copiedLabel : label}
    </button>
  );
}
