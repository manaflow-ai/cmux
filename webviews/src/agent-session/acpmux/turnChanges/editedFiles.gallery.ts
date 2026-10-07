// l10n-allow-file: gallery fixtures (sample prompts, paths and file text), not shipped UI.
// The edited-files card (conversation/EditedFilesCard.tsx, turnChanges/*) in each of its states
// (D7): the file rows, "Show N more" past agentPane.editedFiles.maxRows, the hash-checked Undo and
// its confirmation, a file that changed since the turn, an edit Undo cannot reverse, and the
// collapsed and never settings. turn.undo answers come from the variant's `native` map, the shape
// the Swift host (AgentPaneTurnUndo.swift) sends.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";

type Edit = { path: string; oldText?: string; newText: string };

const retry = "export const tries = 3;\nexport const delayMs = 250;\n";
const FILES: Edit[] = [
  {
    path: "src/net/client.ts",
    oldText: "export const fetchJSON = fetch;\n",
    newText: `import { withRetry } from "./retry";\nexport const fetchJSON = withRetry(fetch);\n`,
  },
  { path: "src/net/retry.ts", newText: retry },
  {
    path: "test/net/retry.test.ts",
    oldText: "",
    newText: `import { tries } from "../../src/net/retry";\ntest("tries", () => expect(tries).toBe(3));\n`,
  },
];
const MANY: Edit[] = Array.from({ length: 8 }, (_, index) => ({
  path: `src/feature/part-${index + 1}.ts`,
  oldText: `export const part = ${index};\n`,
  newText: `export const part = ${index + 1};\nexport const label = "part ${index + 1}";\n`,
}));

/// One finished turn that wrote `files` with whole-text edits (each file's before and after).
function turn(files: Edit[], prompt = "Add retries with backoff to the fetch helper") {
  return chat([
    user(prompt, 6),
    activity(
      files.map((file) => tool(`Edit ${file.path}`, "edit", "completed", { diffs: [file] })),
      5.9,
    ),
    assistant("Done: the client retries through withRetry, with tests.", 5.2),
    summary(5.2, { status: "completed", toolCount: files.length }),
  ]);
}

const setting =
  (value: Record<string, unknown>): Play =>
  async ({ document, waitFor }) => {
    (document.defaultView as unknown as { cmuxAcpmuxEditedFiles?: (value: unknown) => void }).cmuxAcpmuxEditedFiles?.(
      value,
    );
    await waitFor(() => true);
  };
const clickUndo: Play = async ({ click, waitFor, document }) => {
  await waitFor(() => document.querySelector(".acpmux-edited-undo"));
  await click({ selector: ".acpmux-edited-undo" });
  await waitFor(() => document.querySelector(".acpmux-edited-confirm"));
};
const dryRun = (statuses: Record<string, string>) => ({
  "turn.undo": { files: Object.entries(statuses).map(([path, status]) => ({ path, status })) },
});

const variants: Record<string, AgentPaneVariant> = {
  rows: {
    note: "Three edited files (one new): the rows with their counts, Undo and View changes.",
    snapshot: turn(FILES),
  },
  "show-more": {
    note: "Eight files with maxRows 5: five rows, then Show 3 more.",
    snapshot: turn(MANY, "Bump every part"),
  },
  "undo-confirm": {
    note: "After the Undo click: the dry run says all three files go back.",
    snapshot: turn(FILES),
    native: dryRun({
      "src/net/client.ts": "wouldRevert",
      "src/net/retry.ts": "wouldTrash",
      "test/net/retry.test.ts": "wouldRevert",
    }),
    play: clickUndo,
  },
  "changed-since-turn": {
    note: "The dry run finds client.ts changed after the turn: Undo leaves it and puts back the other two.",
    snapshot: turn(FILES),
    native: dryRun({
      "src/net/client.ts": "changed",
      "src/net/retry.ts": "wouldTrash",
      "test/net/retry.test.ts": "wouldRevert",
    }),
    play: clickUndo,
  },
  "cannot-undo": {
    note: "Fragment edits (no whole before and after text): no exact Undo, the card says so.",
    snapshot: chat([
      user("Rename the helper", 6),
      activity(
        [
          tool("Edit src/net/client.ts", "edit", "completed", {
            diffs: [{ path: "src/net/client.ts", oldText: "fetchJSON", newText: "getJSON", line: 2 }],
          }),
        ],
        5.9,
      ),
      summary(5.2, { status: "completed", toolCount: 1 }),
    ]),
  },
  collapsed: {
    note: "agentPane.editedFiles.show = collapsed: the header only; its chevron shows the rows.",
    snapshot: turn(FILES),
    play: setting({ show: "collapsed", maxRows: 5, scope: "turn" }),
  },
  never: {
    note: "agentPane.editedFiles.show = never: no card, the plain tool rows.",
    snapshot: turn(FILES),
    play: setting({ show: "never", maxRows: 5, scope: "turn" }),
  },
};

export default agentPaneEntry({
  id: "agent-pane.edited-files",
  title: "Edited files card",
  area: "Agent pane",
  covers: ["agent-session/acpmux/conversation/EditedFilesCard.tsx"],
  variants,
});
