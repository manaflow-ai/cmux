"use client";

// Live tuner for the real DownloadButton. Renders both sizes at once and drives
// each one's padding via the component's `padOverride` prop, so the divider
// spacing can be dialed in per size and copied back into download-button.tsx.
// Diagnostic toggles (re-add transition, drop translateZ, magnify) exist to
// pin down the Safari hover jump. Reach it at /debug. Not linked from anywhere.

import { type CSSProperties, useState } from "react";
import { DownloadButton } from "../components/download-button";

type Pad = {
  downloadLeft: number;
  downloadRight: number;
  caretLeft: number;
  caretRight: number;
};
type Size = "default" | "sm";

// Mirrors the values baked into download-button.tsx so /debug opens on the
// currently-shipped spacing.
const INITIAL: Record<Size, Pad> = {
  default: { downloadLeft: 20, downloadRight: 9, caretLeft: 7, caretRight: 11 },
  sm: { downloadLeft: 12, downloadRight: 7, caretLeft: 5, caretRight: 9 },
};

const FIELDS: { key: keyof Pad; label: string; accent: string }[] = [
  { key: "downloadRight", label: "Left of divider  (download pr)", accent: "#3b82f6" },
  { key: "caretLeft", label: "Right of divider  (caret pl)", accent: "#f97316" },
  { key: "downloadLeft", label: "Outer left  (before icon)", accent: "#9ca3af" },
  { key: "caretRight", label: "Outer right  (after caret)", accent: "#9ca3af" },
];

// px -> Tailwind spacing token (v4: 1 unit = 4px; .5 steps ok; else arbitrary)
function tw(prefix: string, px: number) {
  if (px % 4 === 0) return `${prefix}-${px / 4}`;
  if (px % 2 === 0) return `${prefix}-${px / 4}`; // e.g. 10 -> 2.5, 6 -> 1.5
  return `${prefix}-[${px}px]`;
}

export default function DownloadButtonDebug() {
  const [pad, setPad] = useState<Record<Size, Pad>>(() => structuredClone(INITIAL));
  const [dark, setDark] = useState(true);
  const [zoom, setZoom] = useState(1);
  const [reTransition, setReTransition] = useState(false);
  const [forceTranslateZ, setForceTranslateZ] = useState(false);
  const [copied, setCopied] = useState(false);

  const set = (size: Size, key: keyof Pad, v: number) =>
    setPad((p) => ({ ...p, [size]: { ...p[size], [key]: v } }));

  const resetSize = (size: Size) =>
    setPad((p) => ({ ...p, [size]: { ...INITIAL[size] } }));

  const classesFor = (size: Size) => {
    const p = pad[size];
    return {
      download: `${tw("pl", p.downloadLeft)} ${tw("pr", p.downloadRight)}`,
      caret:
        p.caretLeft === p.caretRight
          ? tw("px", p.caretLeft)
          : `${tw("pl", p.caretLeft)} ${tw("pr", p.caretRight)}`,
    };
  };

  const snippet = () => {
    const d = classesFor("default");
    const s = classesFor("sm");
    return [
      "// download zone padding",
      `default download: ${d.download}   caret: ${d.caret}`,
      `sm      download: ${s.download}   caret: ${s.caret}`,
      "",
      "// raw px",
      `default: ${JSON.stringify(pad.default)}`,
      `sm:      ${JSON.stringify(pad.sm)}`,
    ].join("\n");
  };

  const copy = async () => {
    await navigator.clipboard.writeText(snippet());
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1200);
  };

  const wrapClass = [
    reTransition ? "dbg-retrans" : "",
    forceTranslateZ ? "dbg-tz" : "",
  ]
    .filter(Boolean)
    .join(" ");

  return (
    <div className="mx-auto max-w-6xl p-8">
      {/* Diagnostic CSS scoped to the previews */}
      <style>{`
        .dbg-retrans a, .dbg-retrans button { transition: background-color .15s ease !important; }
        .dbg-retrans svg { transition: opacity .15s ease !important; }
        .dbg-tz > div:first-child { transform: translateZ(0) !important; }
      `}</style>

      <h1 className="text-lg font-semibold">DownloadButton debug</h1>
      <p className="mb-6 text-sm text-muted">
        Both sizes render the real component; sliders drive its{" "}
        <code className="rounded bg-code-bg px-1">padOverride</code>. Hover each
        button to check the jump. Copy classes into{" "}
        <code className="rounded bg-code-bg px-1">
          web/app/[locale]/components/download-button.tsx
        </code>
        .
      </p>

      {/* toolbar */}
      <div className="mb-6 flex flex-wrap items-center gap-5 text-sm">
        <label className="flex items-center gap-2">
          <input type="checkbox" checked={dark} onChange={(e) => setDark(e.target.checked)} />
          dark bg
        </label>
        <label className="flex items-center gap-2">
          zoom
          <input type="range" min={1} max={8} step={0.5} value={zoom}
            onChange={(e) => setZoom(Number(e.target.value))} />
          <span className="w-8 tabular-nums">{zoom}×</span>
        </label>
        <label className="flex items-center gap-2 text-blue-600">
          <input type="checkbox" checked={reTransition}
            onChange={(e) => setReTransition(e.target.checked)} />
          re-add hover transition (diagnostic: should reintroduce the jump)
        </label>
        <label className="flex items-center gap-2 text-blue-600">
          <input type="checkbox" checked={forceTranslateZ}
            onChange={(e) => setForceTranslateZ(e.target.checked)} />
          force translateZ on pill (diagnostic: should reintroduce the jump)
        </label>
      </div>

      {/* previews + sliders, one column per size */}
      <div className="grid gap-8 md:grid-cols-2">
        {(["default", "sm"] as const).map((size) => (
          <div key={size} className="rounded-xl border border-border p-4">
            <div className="mb-3 flex items-center justify-between">
              <span className="text-sm font-semibold uppercase tracking-wide text-muted">
                {size}
              </span>
              <button
                onClick={() => resetSize(size)}
                className="rounded-md border border-border px-2 py-0.5 text-xs text-muted hover:text-foreground"
              >
                reset {size}
              </button>
            </div>

            <div
              className={dark ? "dark" : undefined}
              style={
                {
                  // Pin the theme tokens so the pill has correct contrast even
                  // though the surrounding app may be in the other mode.
                  "--background": dark ? "#0a0a0a" : "#fafafa",
                  "--foreground": dark ? "#ededed" : "#171717",
                  background: dark ? "#0a0a0a" : "#fafafa",
                  borderRadius: 12,
                  padding: "48px 24px",
                  overflow: "auto",
                  display: "flex",
                  justifyContent: "center",
                } as CSSProperties
              }
            >
              <div
                className={wrapClass}
                style={{
                  transform: `scale(${zoom})`,
                  transformOrigin: "center",
                  display: "flex",
                  alignItems: "center",
                  gap: size === "sm" ? 20 : 14,
                  color: "var(--foreground)",
                }}
              >
                {size === "sm" && (
                  <>
                    <span style={{ fontSize: 14, fontWeight: 500, opacity: 0.7 }}>Docs</span>
                    <span style={{ fontSize: 14, fontWeight: 500, opacity: 0.7 }}>Blog</span>
                  </>
                )}
                <DownloadButton size={size} location="debug" padOverride={pad[size]} />
                {size === "default" && (
                  <span
                    style={{
                      display: "inline-flex",
                      alignItems: "center",
                      borderRadius: 9999,
                      border: "1px solid color-mix(in srgb, var(--foreground) 18%, transparent)",
                      padding: "10px 20px",
                      fontSize: 15,
                      fontWeight: 500,
                    }}
                  >
                    View on GitHub
                  </span>
                )}
              </div>
            </div>

            <div className="mt-4 space-y-3">
              {FIELDS.map((f) => (
                <div key={f.key}>
                  <div className="mb-1 flex items-center justify-between text-sm">
                    <span className="flex items-center gap-2 font-medium">
                      <span className="inline-block h-2 w-2 rounded-sm"
                        style={{ background: f.accent }} />
                      {f.label}
                    </span>
                    <span className="flex items-center gap-1.5">
                      <button
                        type="button"
                        onClick={() => set(size, f.key, INITIAL[size][f.key])}
                        disabled={pad[size][f.key] === INITIAL[size][f.key]}
                        title={`reset to ${INITIAL[size][f.key]}px`}
                        className="rounded px-1 leading-none text-muted hover:text-foreground disabled:opacity-25"
                      >
                        ↺
                      </button>
                      <input type="number" min={0} max={40} value={pad[size][f.key]}
                        onChange={(e) => set(size, f.key, Number(e.target.value))}
                        className="w-14 rounded border border-border bg-transparent px-2 py-0.5 text-right text-sm" />
                    </span>
                  </div>
                  <input type="range" min={0} max={40} step={1} value={pad[size][f.key]}
                    onChange={(e) => set(size, f.key, Number(e.target.value))}
                    className="w-full" />
                </div>
              ))}
              <div className="pt-1 font-mono text-xs text-muted">
                download {classesFor(size).download} · caret {classesFor(size).caret}
              </div>
            </div>
          </div>
        ))}
      </div>

      {/* output */}
      <div className="mt-8">
        <button onClick={copy}
          className="mb-2 rounded-md bg-foreground px-4 py-2 text-sm font-medium text-background">
          {copied ? "Copied ✓" : "Copy classes + px (both sizes)"}
        </button>
        <pre className="overflow-auto rounded-lg border border-border bg-code-bg p-3 font-mono text-xs">
          {snippet()}
        </pre>
      </div>
    </div>
  );
}
