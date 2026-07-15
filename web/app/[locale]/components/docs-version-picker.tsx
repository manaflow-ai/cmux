"use client";

import { docsChannelUrl } from "@/app/lib/docs-channel";

export function DocsVersionPicker({
  channel,
  releaseLabel,
  nightlyLabel,
}: {
  channel: "release" | "nightly";
  releaseLabel: string;
  nightlyLabel: string;
}) {
  const label = `${releaseLabel} / ${nightlyLabel}`;

  return (
    <label className="block px-3 pt-4 pb-4" data-pagefind-ignore="all">
      <span className="sr-only">{label}</span>
      <select
        aria-label={label}
        value={channel}
        onChange={(event) => {
          const value = event.target.value as "release" | "nightly";
          if (value === channel) return;
          const { pathname, search, hash } = window.location;
          window.location.assign(docsChannelUrl(value, pathname, search, hash));
        }}
        className="w-full rounded-md border border-border bg-background px-2 py-1.5 text-[13px] text-foreground"
      >
        <option value="release">{releaseLabel}</option>
        <option value="nightly">{nightlyLabel}</option>
      </select>
    </label>
  );
}
