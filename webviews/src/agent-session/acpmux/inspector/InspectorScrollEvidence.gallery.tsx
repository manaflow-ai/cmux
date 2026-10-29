// l10n-allow-file: deterministic fixture labels for a private scroll-behavior audit.
import type { CSSProperties } from "react";
import { componentEntry } from "../../../gallery/format";
import type { TurnFile } from "../diff";
import { OutputsSection } from "./OutputsSection";
import { TasksSection } from "./TasksSection";
import type { BackgroundCommand } from "./processes";

type Props = {
  count?: number;
  height?: "short" | "tall";
  arm?: "current" | "outer-only";
};

const now = Date.now();

const files = (count: number): TurnFile[] =>
  Array.from({ length: count }, (_, index) => ({
    path: `/workspace/src/output-${String(index + 1).padStart(4, "0")}.ts`,
    displayPath: `src/output-${String(index + 1).padStart(4, "0")}.ts`,
    edits: [],
    additions: index + 1,
    deletions: index % 3,
    created: index % 2 === 0,
  }));

const tasks = (count: number): BackgroundCommand[] =>
  Array.from({ length: count }, (_, index) => ({
    id: `scroll-evidence-${index + 1}`,
    command: `bun test --filter output-${String(index + 1).padStart(4, "0")}`,
    state: "running" as const,
    processId: `process-${index + 1}`,
    startedAt: now - (index + 1) * 30_000,
  }));

function InspectorScrollEvidence({ count = 12, height = "tall", arm = "current" }: Props) {
  const style = { "--acpmux-inspector-max-height": "none" } as CSSProperties;
  return (
    <main
      className="acpmux-scroll-evidence"
      data-arm={arm}
      data-height={height}
      style={style}
      aria-label={`Session Info scroll evidence: ${count} rows, ${arm}, ${height}`}
    >
      <p className="acpmux-scroll-evidence__label">
        {arm === "current" ? "Current inner list ceiling" : "Outer-only comparison"} · {count} rows · {height}
      </p>
      <section className="acpmux-scroll-evidence__section" aria-labelledby="outputs-heading">
        <h2 id="outputs-heading">Outputs</h2>
        <OutputsSection files={files(count)} links={[]} artifacts={0} />
      </section>
      <section className="acpmux-scroll-evidence__section" aria-labelledby="tasks-heading">
        <h2 id="tasks-heading">Background tasks</h2>
        <TasksSection commands={tasks(count)} />
      </section>
    </main>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.chat-inspector-scroll-evidence",
  title: "Session Info scroll evidence",
  area: "Agent pane",
  pane: true,
  height: 900,
  widths: { narrow: 320, normal: 420 },
  covers: [
    "agent-session/acpmux/inspector/OutputsSection.tsx",
    "agent-session/acpmux/inspector/TasksSection.tsx",
    "agent-session/acpmux/inspector/inspector.css",
  ],
  load: async () => InspectorScrollEvidence,
  styles: () => Promise.all([import("./inspector.css"), import("./InspectorScrollEvidence.gallery.css")]),
  variants: {
    "current-0-tall": { note: "Current production ceiling with no rows.", props: { count: 0, height: "tall", arm: "current" } },
    "current-1-tall": { note: "Current production ceiling with one row.", props: { count: 1, height: "tall", arm: "current" } },
    "current-12-tall": { note: "Current production ceiling with 12 rows in a tall panel.", props: { count: 12, height: "tall", arm: "current" } },
    "current-1000-short": { note: "Current production ceiling with 1,000 rows in a short panel.", props: { count: 1000, height: "short", arm: "current" } },
    "outer-only-12-tall": { note: "Comparison: outer panel owns scroll with 12 rows.", props: { count: 12, height: "tall", arm: "outer-only" } },
    "outer-only-1000-short": { note: "Comparison: outer panel owns scroll with 1,000 rows.", props: { count: 1000, height: "short", arm: "outer-only" } },
  },
});
