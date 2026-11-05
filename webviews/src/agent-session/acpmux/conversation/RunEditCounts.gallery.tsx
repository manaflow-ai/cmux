// l10n-allow-file: gallery fixture paths, commands and file text, not shipped copy.
// A collapsed run's summary line with its edits' line totals (Leo 2026-10-30: "i like claude code
// they put the number overarching too"). Drawn through the real ToolRows path: a finished run of
// two edits and a command folds under one line ("Edited 2 files, ran a command +7 -2"), a run
// with no edits has no count, and a long summary in a narrow pane cuts while its totals stay.
// Versions: before (no totals on the run's line), the shipped one (totals right after the
// summary, as Claude Code desktop puts them), totals at the row's trailing edge before the
// chevron, and added lines only.
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import { activity, tool } from "../../../gallery/fixtures/acpmux";
import { useEffect } from "react";
import { ToolRows } from "./TurnRows";
import { resetTranscriptDisclosure } from "./transcriptDisclosure";

type Look = "before" | "inline" | "trailing" | "added-only";
type Props = { look: Look; mode: "light" | "dark" };

const SESSION = "gallery-run-edit-counts";

const edit = (path: string, oldText: string, newText: string) =>
  tool(`Edit ${path}`, "edit", "completed", { diffs: [{ path, oldText, newText }] });
const command = (text: string, output = "") => tool(text, "execute", "completed", { command: text, output });

const runs = [
  activity(
    [
      edit(
        "/Users/you/src/atlas-web/src/retry.ts",
        "export function retry(run) {\n  return run();\n}\n",
        "export function retry(run, attempts = 3) {\n  for (let n = 1; n < attempts; n++) {\n    try { return run(); } catch {}\n  }\n  return run();\n}\n",
      ),
      command("bun test retry", "4 pass\n"),
      edit("/Users/you/src/atlas-web/notes/retry.md", "", "Retry runs three times.\nThe last failure throws.\n"),
    ],
    4,
    { id: "run-edits", foldRun: true },
  ),
  activity([command("git status", "On branch retry\n"), command("bun run lint", "0 problems\n")], 3, {
    id: "run-commands",
    foldRun: true,
  }),
  activity(
    [
      tool("Read src/retry.ts", "read", "completed", {
        locations: [{ path: "/Users/you/src/atlas-web/src/retry.ts" }],
      }),
      tool("Search for retry callers", "search", "completed"),
      command("bun test --filter retry-and-backoff-integration", "12 pass\n"),
      edit("/Users/you/src/atlas-web/src/backoff.ts", "export const backoff = 100;\n", "export const backoff = 250;\n"),
      command("git diff --stat", " 1 file changed\n"),
    ],
    2,
    { id: "run-long", foldRun: true },
  ),
];

function RunEditCountsGallery({ look, mode }: Props) {
  useEffect(() => resetTranscriptDisclosure(SESSION), []);
  return (
    <main
      className="run-edit-counts-gallery acpmux-conversation"
      data-mode={mode}
      data-look={look}
      data-run-edit-counts
    >
      {runs.map((row) => (
        <section key={row.id} className="run-edit-counts-gallery__row" data-run={row.id}>
          <ToolRows row={row} sessionId={SESSION} />
        </section>
      ))}
    </main>
  );
}

const variant = (look: Look, mode: Props["mode"], note: string): ComponentVariant<Props> => ({
  note: `${note} ${mode === "dark" ? "Dark" : "Light"} theme.`,
  props: { look, mode },
});

export default componentEntry<Props>({
  id: "agent-pane.run-edit-counts",
  title: "Tool runs: edit totals on the summary line",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 360, normal: 640, wide: 900 },
  anchors: [{ selector: "[data-run-edit-counts]" }],
  covers: [
    "agent-session/acpmux/conversation/EditCounts.tsx",
    "agent-session/acpmux/conversation/ToolRun.tsx",
    "agent-session/acpmux/conversation/ToolGroupRow.tsx",
  ],
  styles: () => import("./RunEditCounts.gallery.css"),
  load: async () => RunEditCountsGallery,
  keywords: ["edits", "lines", "added", "removed", "count", "claude code", "summary"],
  variants: {
    before: variant("before", "light", "Before: the run's line names its work and no totals."),
    inline: variant("inline", "light", "Shipped: +N/-N right after the summary; the summary cuts, the totals stay."),
    "inline-dark": variant(
      "inline",
      "dark",
      "Shipped: +N/-N right after the summary; the summary cuts, the totals stay.",
    ),
    trailing: variant("trailing", "light", "Totals at the row's trailing edge, before the chevron."),
    "added-only": variant("added-only", "light", "Added lines only, as Claude Code's collapsed row reads."),
  },
});
