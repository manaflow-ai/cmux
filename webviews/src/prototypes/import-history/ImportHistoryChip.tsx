// l10n-allow-file: isolated gallery prototype, not shipped UI.
// Placement (c): one quiet chip under the New Tab composer on a Mac whose Claude Code or Codex history
// is not in cmux yet. The chip names both tools and the counts; its body starts the import and the ×
// hides it (the app would remember that, as the import cards' Not Now does).
import "./importHistory.css";

export type ImportHistoryChipProps = {
  title: string;
  counts: string;
  state: "ready" | "running";
  running: string;
  dismiss: string;
  onStart(): void;
  onDismiss(): void;
};

export function ImportHistoryChip(props: ImportHistoryChipProps) {
  const running = props.state === "running";
  return (
    <div className="ih-chip-row">
      <div className="ih-chip" data-state={props.state}>
        <button type="button" className="ih-chip-body" disabled={running} onClick={props.onStart}>
          <svg className="ih-chip-glyph" viewBox="0 0 16 16" aria-hidden="true">
            <path
              d="M8 2.5v7.5M4.75 7 8 10.25 11.25 7M3 12.75h10"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.4"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
          <span className="ih-chip-title">{running ? props.running : props.title}</span>
          {!running && <span className="ih-chip-counts">{props.counts}</span>}
        </button>
        {!running && (
          <button type="button" className="ih-chip-close" aria-label={props.dismiss} onClick={props.onDismiss}>
            <svg viewBox="0 0 16 16" aria-hidden="true">
              <path
                d="M4.5 4.5l7 7M11.5 4.5l-7 7"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.4"
                strokeLinecap="round"
              />
            </svg>
          </button>
        )}
      </div>
    </div>
  );
}
