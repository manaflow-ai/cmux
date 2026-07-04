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
      className="rounded-md border border-border px-3 py-2 text-sm text-muted transition-colors hover:text-foreground"
    >
      {copied ? copiedLabel : label}
    </button>
  );
}
