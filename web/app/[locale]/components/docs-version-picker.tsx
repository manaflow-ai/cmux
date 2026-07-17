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
        className="h-[30px] w-full appearance-auto border-0 bg-transparent px-1 py-0 text-[13px] text-muted-foreground shadow-none outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
      >
        <option value="release">{releaseLabel}</option>
        <option value="nightly">{nightlyLabel}</option>
      </select>
    </label>
  );
}
