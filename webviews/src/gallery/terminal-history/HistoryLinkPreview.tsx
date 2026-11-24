// l10n-allow-file: gallery fixtures, not shipped UI.
import type { CSSProperties } from "react";

export type HistoryLinkProps = { variant: "dated" | "compact" | "undated" | "separator" };

export function HistoryLinkPreview({ variant }: HistoryLinkProps) {
  const label = variant === "undated" ? "Earlier history — open as chat" : "Earlier history (13 days) — open as chat";
  const button: CSSProperties = {
    color: "var(--fg)",
    background: "var(--surface)",
    border: "1px solid var(--border)",
    borderRadius: 5,
    font: "caption",
    whiteSpace: "nowrap",
    padding: "2px 6px",
  };
  return (
    <div style={{ padding: 8, width: variant === "compact" ? 160 : "100%", boxSizing: "border-box" }}>
      <div style={{ display: "flex", justifyContent: variant === "separator" ? "center" : "flex-end" }}>
        <button type="button" style={button} aria-label={label} title={label}>
          <span aria-hidden="true">↶</span>
          {variant !== "compact" && " " + label}
        </button>
      </div>
      <pre style={{ fontSize: "var(--text-detail)" }}>{"Session resumed\n\n› "}</pre>
    </div>
  );
}
