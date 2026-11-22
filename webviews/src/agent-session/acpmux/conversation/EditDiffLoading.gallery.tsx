// l10n-allow-file: deterministic inline edit fixtures, never chat content.
import { componentEntry } from "../../../gallery/format";
import type { DiffHunk, TurnFile } from "../diff";
import { EditDiff, EditDiffFrame } from "./EditDiff";

const deferred = new Promise<never>(() => {});
function PendingHunks(): never {
  throw deferred;
}

const PROSE_LINE =
  "Retries back off with full jitter, so a burst of failures spreads out instead of hammering the upstream again at the same instant.";

function added(count: number, start: number, text: (line: number) => string): DiffHunk {
  return {
    lines: Array.from({ length: count }, (_, index) => ({
      type: "add" as const,
      text: text(start + index),
      newLine: start + index,
    })),
  };
}

type Fixture = "code" | "prose" | "hunks";

function fixture(kind: Fixture, lines: number, numbered: boolean): TurnFile {
  const path = kind === "prose" ? "docs/retry-policy.md" : "src/retry-policy.ts";
  const hunks: DiffHunk[] =
    kind === "hunks"
      ? // Mid-file hunks: Pierre draws a separator before each, for the lines it skips.
        [added(3, 40, (line) => `retry(${line});`), added(2, 120, (line) => `retry(${line});`)]
      : lines
        ? [added(lines, 1, (line) => (kind === "prose" ? `${line}. ${PROSE_LINE}` : `retry(${line});`))]
        : [];
  const count = hunks.reduce((sum, hunk) => sum + hunk.lines.length, 0);
  return {
    path,
    displayPath: path,
    additions: count,
    deletions: 0,
    created: kind !== "hunks",
    edits: [{ toolId: "retry-policy", numbered, hunks }],
  };
}
type Props = { kind?: Fixture; lines?: number; numbered?: boolean; loaded?: boolean; whole?: boolean };
function InlineDiffLoading({ kind = "code", lines = 3, numbered = true, loaded = false, whole = false }: Props) {
  const file = fixture(kind, lines, numbered);
  return loaded ? (
    <EditDiff file={file} whole={whole} />
  ) : (
    <EditDiffFrame file={file} whole={whole} hunks={PendingHunks} />
  );
}
export default componentEntry<Props>({
  id: "agent-pane.inline-diff-loading",
  title: "Inline edit loading",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 320, normal: 640 },
  covers: ["agent-session/acpmux/conversation/EditDiff.tsx", "agent-session/acpmux/conversation/EditDiffLoading.tsx"],
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  load: async () => InlineDiffLoading,
  variants: {
    short: { props: { lines: 3 }, note: "Deferred renderer with three known lines." },
    preview: { props: { lines: 1284 }, note: "Large edit retains the eight-line preview and expansion control." },
    fragment: { props: { lines: 3, numbered: false }, note: "Unnumbered edit has no fabricated line-number gutter." },
    empty: { props: { lines: 0 }, note: "Known empty edit retains its existing explanation while the chunk loads." },
    loaded: { props: { lines: 3, loaded: true }, note: "The same edit after the renderer loads." },
    "fragment-loaded": {
      props: { lines: 3, numbered: false, loaded: true },
      note: "The fragment after the renderer loads.",
    },
    prose: {
      props: { kind: "prose", lines: 5 },
      note: "A Markdown edit's long lines wrap under their start while the chunk loads, as tall as the rendered diff.",
    },
    "prose-loaded": {
      props: { kind: "prose", lines: 5, loaded: true },
      note: "The wrapped edit after the renderer loads.",
    },
    hunks: {
      props: { kind: "hunks" },
      note: "Mid-file hunks keep the room of the separators the rendered diff draws before them.",
    },
    "hunks-loaded": { props: { kind: "hunks", loaded: true }, note: "The mid-file hunks after the renderer loads." },
  },
});
