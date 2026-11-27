// l10n-allow-file: gallery fixtures (sample prompts, paths and file text), not shipped UI.
// The edited-files card (conversation/EditedFilesCard.tsx, turnChanges/*) in each of its states
// (D7): its one row, the same row opened into every file's diff stacked under sticky repo-relative
// names (Leo, 2026-11-25: "what do you think about just having one row that expands out to the
// widest situation?"), the hash-checked Undo and its confirmation, a file that changed since the
// turn, an edit Undo cannot reverse, and the collapsed and never settings. turn.undo answers come
// from the variant's `native` map, the shape the Swift host (AgentPaneTurnUndo.swift) sends. A
// change opens inline, inside the card (Leo, 2026-11-25: "im saying inline tho. like the jump button
// can take you out of inline and into its own but i like the option to view inline"); each file's
// Open in Changes icon is the way to the changes pane; no View changes button.
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
/// A Markdown file and an HTML page the agent wrote (no old text: new files).
const PLAN: Edit = {
  path: "/Users/you/src/atlas-web/docs/retry-plan.md",
  newText: "# Retry plan\n\n- Three tries, 250 ms apart\n- Backoff doubles\n",
};
const REPORT: Edit = {
  path: "/Users/you/src/atlas-web/reports/retries.html",
  newText: "<!doctype html>\n<title>Retries</title>\n<h1>Retries</h1>\n",
};
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

/// Two finished turns that each edited files: an earlier card and the chat's latest one.
function twoTurns() {
  return chat([
    user("Add retries with backoff to the fetch helper", 12),
    activity(
      FILES.map((file) => tool(`Edit ${file.path}`, "edit", "completed", { diffs: [file] })),
      11.9,
    ),
    assistant("Done: the client retries through withRetry, with tests.", 11.2),
    summary(11.2, { status: "completed", toolCount: FILES.length }),
    user("Make the retry count a setting", 6),
    activity(
      [
        tool(`Edit ${FILES[1]!.path}`, "edit", "completed", {
          diffs: [{ ...FILES[1]!, oldText: retry, newText: retry.replace("3", "5") }],
        }),
      ],
      5.9,
    ),
    assistant("The retry count reads the setting now.", 5.2),
    summary(5.2, { status: "completed", toolCount: 1 }),
  ]);
}
const EARLIER = ".acpmux-edited[data-earlier]";

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

/// Two files the agent wrote by their whole paths: the card names them from the chat's folder.
const ROOT = "/Users/you/src/atlas-web";
const TWO: Edit[] = [
  { ...FILES[0]!, path: `${ROOT}/src/net/client.ts` },
  {
    ...FILES[2]!,
    path: `${ROOT}/tools/timer_run.py`,
    newText: "import time\n\nstart = time.time()\nprint(time.time() - start)\n",
  },
];
const SIX: Edit[] = FOURTEEN.slice(0, 6).map((file) => ({ ...file, path: `${ROOT}/${file.path}` }));

/// Click the card's row; every file's diff opens stacked inside it.
const openCard: Play = async ({ click, waitFor, document }) => {
  await waitFor(() => document.querySelector(".acpmux-edited-head"));
  await click({ selector: ".acpmux-edited-head" });
  await waitFor(() => document.querySelector(".acpmux-edited-stack .cv-edit-diff__hunks"));
};

const variants: Record<string, AgentPaneVariant> = {
  "earlier-at-rest": {
    note: "Two turns that edited files: each card is one row with its Undo at rest, and opens its changes inside itself; no View changes button.",
    height: 700,
    snapshot: twoTurns(),
    play: async ({ waitFor, document }) => {
      await waitFor(() => document.querySelector(EARLIER));
    },
  },
  "earlier-hovered": {
    note: "The pointer on the earlier card's header: the whole header washes and its chevron lights, the one sign it opens. The counts stay counts.",
    height: 700,
    snapshot: twoTurns(),
    play: async ({ hover, waitFor, document }) => {
      await waitFor(() => document.querySelector(EARLIER));
      await hover({ selector: `${EARLIER} .acpmux-edited-head` });
      if (document.querySelector(".acpmux-review-changes, .acpmux-edited-summary-link"))
        throw new Error("the card shows a second way to its changes");
    },
  },
  "earlier-focused": {
    note: "Tab onto the earlier card's chevron, the keyboard way into its stacked diffs; Undo stays where it sits.",
    height: 700,
    snapshot: twoTurns(),
    play: async ({ focus, waitFor, document }) => {
      await waitFor(() => document.querySelector(`${EARLIER} .acpmux-edited-chevron`));
      await focus({ selector: `${EARLIER} .acpmux-edited-chevron` });
    },
  },
  "one-file": {
    note: "One edited file: the card names it, its counts, Undo and the chevron that opens its diff inside the card.",
    snapshot: turn([FILES[0]!], "Wrap fetch in withRetry"),
  },
  "inline-diff-open": {
    note: "Play: click the one-file card's header; the file's diff opens inside the card, its Open in Changes icon in the diff's header.",
    height: 640,
    snapshot: turn([FILES[0]!], "Wrap fetch in withRetry"),
    play: async ({ click, waitFor, document }) => {
      await waitFor(() => document.querySelector(".acpmux-edited-head"));
      await click({ selector: ".acpmux-edited-head" });
      await waitFor(() => document.querySelector(".acpmux-edited-stack .cv-edit-diff"));
      if (!document.querySelector(".acpmux-edited-stack .acpmux-edited-open"))
        throw new Error("the opened diff has no Open in Changes");
    },
  },
  narrow: {
    note: "One edited file with a long name; at the narrow width (240 px for this entry) Undo shrinks to its icon and the name ends in an ellipsis, never under a button.",
    snapshot: turn([{ ...FILES[0]!, path: "src/net/backoff/policy/jitter/exponentialWithDecorrelatedJitter.ts" }]),
  },
  "markdown-one": {
    note: "One Markdown file the agent wrote: Open beside View changes shows it in cmux's Markdown page.",
    snapshot: turn([PLAN], "Write up the retry plan"),
  },
  "markdown-mixed": {
    note: "Several files, a Markdown file and an HTML page among them, opened: only the Markdown file's name has Open.",
    height: 900,
    snapshot: turn([FILES[0]!, PLAN, REPORT, FILES[1]!], "Add retries, write up the plan and a report page"),
    play: openCard,
  },
  "markdown-twice": {
    note: "A Markdown file written then edited in one turn: one file, one Open.",
    snapshot: turn(
      [
        PLAN,
        { path: PLAN.path, oldText: PLAN.newText, newText: PLAN.newText + "\n## Rollout\n\nBehind a setting.\n" },
        FILES[1]!,
      ],
      "Write up the retry plan, then add the rollout",
    ),
  },
  "three-files": {
    note: "Three edited files (one new): one row with the totals. No row's floating copy action shows at rest.",
    snapshot: turn(FILES),
    play: async (ctx) => {
      // The prompt's action row: the transcript has drawn. A prompt's bubble row has no floating
      // copy action of its own any more (its Copy is in that row), so none may show here.
      await ctx.waitFor(() => ctx.document.querySelector(".cv-user__actions"));
      for (const copy of ctx.document.querySelectorAll(".acpmux-row__copy")) {
        const style = ctx.document.defaultView!.getComputedStyle(copy);
        if (style.position !== "absolute" || style.opacity !== "0")
          throw new Error(`a row's copy action shows at rest (position ${style.position}, opacity ${style.opacity})`);
      }
    },
  },
  "two-files": {
    note: "Two edited files: one row, Edited 2 files with the totals, Undo and the chevron. No file rows.",
    height: 520,
    snapshot: turn(TWO, "Time the run and retry the fetch"),
    play: async ({ waitFor, document }) => {
      await waitFor(() => document.querySelector(".acpmux-edited-head"));
      if (document.querySelector(".acpmux-edited-file, .acpmux-edited-stack"))
        throw new Error("the closed card draws more than its one row");
    },
  },
  "two-files-open": {
    note: "Play: click the row; both files' whole diffs stack inside the card, each under its sticky repo-relative name (tools/timer_run.py) with its counts and Open in Changes, the card as wide as the transcript.",
    height: 820,
    snapshot: turn(TWO, "Time the run and retry the fetch"),
    play: openCard,
  },
  "six-files": {
    note: "Six edited files, closed: still one row.",
    height: 520,
    snapshot: turn(SIX, "Move the retry policy into its own module"),
  },
  "six-files-open": {
    note: "Play: click the row; six diffs stack in one box at most 60% of the view tall that scrolls once, the name of the file under the top edge pinned there.",
    height: 900,
    snapshot: turn(SIX, "Move the retry policy into its own module"),
    play: async (ctx) => {
      await openCard(ctx);
      const stack = ctx.document.querySelector<HTMLElement>(".acpmux-edited-stack")!;
      stack.scrollTop = 260;
      await ctx.waitFor(() => stack.scrollTop > 0);
    },
  },
  "fourteen-files-open": {
    note: "Fourteen files opened: every diff in the one capped box.",
    height: 900,
    snapshot: turn(FOURTEEN, "Move the retry policy into its own module"),
    play: openCard,
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
    note: "Calls with no diff, opened: the fleet Write (content before file_path), a Codex apply_patch, an opencode write, and one with no path (Unknown file).",
    play: async ({ click, waitFor, document }) => {
      await waitFor(() => document.querySelector(".acpmux-edited-head"));
      await click({ selector: ".acpmux-edited-head" });
      await waitFor(() => document.querySelector(".acpmux-edited-stack"));
    },
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
  "sources-changes": {
    note: "Play: open Sources; Outputs lists the turn's fourteen files, five until View all, and Changes their totals. A file opens the turn's diff at it.",
    height: 700,
    snapshot: turn(FOURTEEN, "Move the retry policy into its own module"),
    play: async ({ click, waitFor, document }) => {
      await click({ selector: ".acpmux-summary-button" });
      await waitFor(() => document.querySelector(".acpmux-summary-card .acpmux-summary-file"));
    },
  },
  collapsed: {
    note: "agentPane.editedFiles.show = collapsed: the one row, as always draws it.",
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
  // Narrow is the card's narrowest layout (cardFit.css: under 260 px Undo is its icon alone).
  widths: { narrow: 240 },
  variants,
});
