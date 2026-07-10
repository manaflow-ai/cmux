"use client";

export function DocsVersionPicker({
  channel,
  releaseLabel,
  nightlyLabel,
  releaseOrigin,
  nightlyOrigin,
}: {
  channel: "release" | "nightly";
  releaseLabel: string;
  nightlyLabel: string;
  releaseOrigin: string;
  nightlyOrigin: string;
}) {
  const current = channel === "release" ? releaseLabel : nightlyLabel;

  return (
    <label className="block px-3 pb-4 text-[12px] text-muted" data-pagefind-ignore="all">
      <span className="sr-only">{`${releaseLabel} / ${nightlyLabel}`}</span>
      <select
        aria-label={`${releaseLabel} / ${nightlyLabel}`}
        className="w-full rounded-md border border-border bg-background px-2 py-1.5 text-foreground"
        value={channel}
        onChange={(event) => {
          const origin = event.target.value === "release" ? releaseOrigin : nightlyOrigin;
          window.location.assign(new URL(window.location.href, origin).toString());
        }}
      >
        <option value={channel}>{current}</option>
        <option value={channel === "release" ? "nightly" : "release"}>
          {channel === "release" ? nightlyLabel : releaseLabel}
        </option>
      </select>
    </label>
  );
}
