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
const FOURTEEN: Edit[] = [
  "src/components/conversation/EditedFilesCard.tsx",
  "src/components/conversation/turnChanges/settings.ts",
  "src/net/client.ts",
  "src/net/retry.ts",
  "src/net/backoff/policy/jitter/exponential.ts",
  "src/net/backoff/policy/index.ts",
  "test/net/retry.test.ts",
  "test/net/backoff.test.ts",
  "docs/networking.md",
  "package.json",
  "src/app/settings/networking/RetrySettingsPanel.tsx",
  "src/app/settings/networking/index.ts",
  "README.md",
  "CHANGELOG.md",
].map((path, index) => ({
  path,
  oldText: Array.from({ length: 3 }, (_, line) => `line ${line}`).join("\n") + "\n",
  newText:
    Array.from({ length: 3 + ((index * 7) % 20) }, (_, line) =>
      line === 1 ? `changed ${index}` : `line ${line}`,
    ).join("\n") + "\n",
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

const showMore: Play = async (ctx) => {
  await setting({ show: "always", maxRows: 3, scope: "turn" })(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-edited-more"));
};
const expandAll: Play = async (ctx) => {
  await showMore(ctx);
  await ctx.click({ selector: ".acpmux-edited-more" });
};

const variants: Record<string, AgentPaneVariant> = {
  "one-file": {
    note: "One edited file: the card names it; Undo and View changes.",
    snapshot: turn([FILES[0]!], "Wrap fetch in withRetry"),
  },
  "three-files": {
    note: "Three edited files (one new): the rows with their counts.",
    snapshot: turn(FILES),
  },
  "fourteen-files": {
    note: "Fourteen files with three rows shown: Show 11 more files. Long directories lose their middle.",
    height: 560,
    snapshot: turn(FOURTEEN, "Move the retry policy into its own module"),
    play: showMore,
  },
  "fourteen-files-expanded": {
    note: "The same fourteen files after Show 11 more files.",
    height: 900,
    snapshot: turn(FOURTEEN, "Move the retry policy into its own module"),
    play: expandAll,
  },
  "undo-pending": {
    note: "After the Undo click: the dry run asks to put back all three files.",
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
    note: "Fragment edits (no whole before and after text): no exact Undo.",
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
  "write-without-diff": {
    note: "Calls with no diff: the fleet Write (content before file_path), a Codex apply_patch, an opencode write, and one with no path (Unknown file).",
    snapshot: chat([
      user("Render the build fleet status", 6),
      activity(
        [
          tool("Write", "edit", "completed", {
            inputSummary: JSON.stringify({
              content:
                'import json, sys, urllib.request, html, datetime\n\nURL = "http://fleet.example.test/v1/status"\n',
              file_path: "/tmp/fleetviz/gen.py",
            }),
          }),
          tool("apply_patch", "edit", "completed", {
            inputSummary: JSON.stringify({
              patch:
                "*** Begin Patch\n*** Update File: src/net/client.ts\n@@\n-a\n+b\n*** Add File: src/net/retry.ts\n+x\n*** End Patch",
            }),
          }),
          tool("write", "edit", "completed", {
            inputSummary: JSON.stringify({
              content: "# Networking\n",
              filePath: "/Users/you/src/atlas-web/docs/networking.md",
            }),
          }),
          tool("Edit", "edit", "completed", { inputSummary: "{}" }),
        ],
        5.9,
      ),
      assistant("Wrote the generator and updated the client.", 5.2),
      summary(5.2, { status: "completed", toolCount: 4 }),
    ]),
  },
  collapsed: {
    note: "agentPane.editedFiles.show = collapsed: the header only; its chevron shows the rows.",
    snapshot: turn(FOURTEEN, "Move the retry policy into its own module"),
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
