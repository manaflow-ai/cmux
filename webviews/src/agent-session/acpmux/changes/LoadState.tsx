// The changes view while a scope loads, when it fails, and when it has nothing, after Codex's
// centered states: "Couldn't load changes" with Retry, and "No changes".
import React from "react";

export function LoadState({ state, onRetry }: { state: "loading" | "error" | "empty"; onRetry: () => void }) {
  if (state === "loading")
    return (
      <output className="acpmux-changes-state">
        <span className="acpmux-changes-state-body">Loading changes…</span>
      </output>
    );
  if (state === "empty")
    return (
      <output className="acpmux-changes-state">
        <strong>No changes</strong>
      </output>
    );
  return (
    <div className="acpmux-changes-state" role="alert">
      <strong>Couldn't load changes</strong>
      <span className="acpmux-changes-state-body">Refresh to try loading the changes again</span>
      <button type="button" className="acpmux-changes-retry" onClick={onRetry}>
        Retry
      </button>
    </div>
  );
}
