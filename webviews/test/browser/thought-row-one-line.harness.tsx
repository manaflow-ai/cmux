// l10n-allow-file: harness fixtures.
// Every one-line step row of a turn, drawn by its own component with the pane's own CSS, for
// thought-row-one-line-browser.test.ts (cmux#52930): a finished thought on its own row and in an
// opened group (ThoughtRow, StepThought), a thought that streams and then finishes, and the tool
// rows beside them (a search and a command, running and done). Every line is far wider than the
// row, so a closed row has lines it must not show.
import { useState } from "react";
import { createRoot } from "react-dom/client";
import type { AcpmuxActivity } from "../../src/agent-session/acpmux/model";
import { StepThought, ThoughtRow } from "../../src/agent-session/acpmux/conversation/ThoughtRow";
import "../../src/pages/shared/desktop.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";

const LINE =
  "So the FFI pin is different from what I expected. I'll read the section in the CI docs on pull requests that change the FFI, then check whether the build pulls the pinned artifact or builds it from source, and which Rust code the app links.";
const thought = (text: string): AcpmuxActivity => ({ kind: "thought", text });
const done = thought(`${LINE}\n\nThen compare the pin with the commit the fleet step built.`);
const oneLine = thought(LINE);
const SEARCH =
  'Searched for "^#|dev build|cmux-ci build|stale FFI|from source|CMUX_APP_FFI|working-tree|pull request|merge base|pinned artifact"';
const COMMAND = "Fetch the PR branch and base, fast-forward, find the merge base, and compare the eight changed files";

function ToolLine({ text, live = false }: { text: string; live?: boolean }) {
  return (
    <button type="button" className={`cv-tool${live ? " is-live" : ""}`} aria-expanded={false}>
      <span className="cv-tool__icon">
        <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
          <rect x="2" y="2" width="12" height="12" rx="2" fill="currentColor" />
        </svg>
      </span>
      <span className="cv-tool__text">{text}</span>
    </button>
  );
}

/** A thought that streams until the test calls `finishThought()`, then folds. */
function StreamingThenDone() {
  const [streaming, setStreaming] = useState(true);
  (window as unknown as { finishThought: () => void }).finishThought = () => setStreaming(false);
  return <ThoughtRow id="streamed" item={done} streaming={streaming} />;
}

const rows: [string, () => React.ReactNode][] = [
  ["thought", () => <ThoughtRow id="t-done" item={done} />],
  ["thought-one-line", () => <ThoughtRow id="t-line" item={oneLine} />],
  ["step-thought", () => <StepThought id="s-done" item={done} />],
  ["step-thought-lead", () => <StepThought id="s-lead" item={done} lead />],
  ["search", () => <ToolLine text={SEARCH} />],
  ["command", () => <ToolLine text={COMMAND} />],
  ["command-live", () => <ToolLine text={COMMAND} live />],
  ["streamed-thought", () => <StreamingThenDone />],
];

document.body.style.margin = "0";
createRoot(document.getElementById("root")!).render(
  <div className="acpmux-scroll" style={{ display: "block", width: 520, padding: "0 16px" }}>
    {rows.map(([id, row]) => (
      <div key={id} className="acpmux-row" data-testid={id} style={{ position: "relative" }}>
        {row()}
      </div>
    ))}
  </div>,
);
requestAnimationFrame(() => {
  document.documentElement.dataset.harnessReady = "true";
});
