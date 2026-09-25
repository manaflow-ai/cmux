"use client";

import { docsChannelUrl, type DocsChannel } from "@/app/lib/docs-channel";

export function DocsVersionPicker({
  channel,
  releaseLabel,
  nightlyLabel,
}: {
  channel: DocsChannel;
  releaseLabel: string;
  nightlyLabel: string;
}) {
  const options: { value: DocsChannel; label: string }[] = [
    { value: "release", label: releaseLabel },
    { value: "nightly", label: nightlyLabel },
  ];

  return (
    <div className="pt-6 pb-4" data-pagefind-ignore="all">
      <div
        role="group"
        aria-label={`${releaseLabel} / ${nightlyLabel}`}
        className="grid grid-cols-2 gap-0.5 rounded-lg border border-border p-0.5"
      >
        {options.map((option) => {
          const selected = option.value === channel;
          return (
            <button
              key={option.value}
              type="button"
              aria-pressed={selected}
              onClick={() => {
                if (selected) return;
                const { pathname, search, hash } = window.location;
                window.location.assign(
                  docsChannelUrl(option.value, pathname, search, hash),
                );
              }}
              className={`h-7 rounded-md text-[13px] transition-colors outline-none focus-visible:ring-2 focus-visible:ring-ring ${
                selected
                  ? "bg-code-bg text-foreground font-medium"
                  : "text-muted hover:text-foreground"
              }`}
            >
              {option.label}
            </button>
          );
        })}
      </div>
    </div>
  );
}
