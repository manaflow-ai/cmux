// l10n-allow-file: deterministic inline edit fixtures, never chat content.
import { componentEntry } from "../../../gallery/format";
import type { TurnFile } from "../diff";
import { EditDiff, EditDiffFrame } from "./EditDiff";

const deferred = new Promise<never>(() => {});
function PendingHunks(): never {
  throw deferred;
}
function fixture(lines: number, numbered: boolean): TurnFile {
  return {
    path: "src/retry-policy.ts",
    displayPath: "src/retry-policy.ts",
    additions: lines,
    deletions: 0,
    created: true,
    edits: [
      {
        toolId: "retry-policy",
        numbered,
        hunks: lines
          ? [
              {
                lines: Array.from({ length: lines }, (_, index) => ({
                  type: "add" as const,
                  text: `retry(${index + 1});`,
                  newLine: index + 1,
                })),
              },
            ]
          : [],
      },
    ],
  };
}
type Props = { lines: number; numbered?: boolean; loaded?: boolean; whole?: boolean };
function InlineDiffLoading({ lines, numbered = true, loaded = false, whole = false }: Props) {
  const file = fixture(lines, numbered);
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
  },
});
