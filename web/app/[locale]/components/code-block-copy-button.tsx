"use client";

import { useCallback, useState } from "react";
import { useTranslations } from "next-intl";

async function copyText(value: string) {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(value);
      return;
    } catch {
      // Fall back for embedded browser contexts that expose the API but reject it.
    }
  }

  const textarea = document.createElement("textarea");
  textarea.value = value;
  textarea.setAttribute("readonly", "");
  textarea.style.position = "fixed";
  textarea.style.opacity = "0";
  document.body.appendChild(textarea);
  textarea.select();
  const copied = document.execCommand("copy");
  textarea.remove();
  if (!copied) {
    throw new Error("Copy failed");
  }
}

function CopyIcon() {
  return (
    <span aria-hidden="true" className="relative h-4 w-4">
      <span className="absolute left-1 top-1 h-3 w-2.5 rounded-[2px] border border-current" />
      <span className="absolute left-0.5 top-0.5 h-3 w-2.5 rounded-[2px] border border-current bg-background" />
    </span>
  );
}

function CheckIcon() {
  return (
    <span
      aria-hidden="true"
      className="h-3.5 w-2 rotate-45 border-b-2 border-r-2 border-current"
    />
  );
}

export function CodeBlockCopyButton({ code }: { code: string }) {
  const t = useTranslations("common");
  const [copied, setCopied] = useState(false);
  const label = copied ? t("copiedCode") : t("copyCode");

  const handleCopy = useCallback(async () => {
    try {
      await copyText(code);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  }, [code]);

  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      onClick={handleCopy}
      onBlur={() => setCopied(false)}
      onPointerLeave={() => setCopied(false)}
      className="docs-code-copy absolute right-2 top-1.5 z-10 flex h-7 w-7 items-center justify-center rounded-md border border-border bg-background/95 text-muted opacity-0 shadow-sm transition hover:text-foreground focus-visible:opacity-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-foreground/20"
    >
      {copied ? <CheckIcon /> : <CopyIcon />}
    </button>
  );
}
