// l10n-allow-file: representative chat fixture prompts, reports and commands, not shipped UI.
import { agentPaneEntry } from "../format";
import { minutesAgo } from "../clock";
import { activity, assistant, chat, row, summary, tool, user } from "../fixtures/acpmux";
import { UPLOADED_AVATAR } from "../fixtures/agentAvatar";
import { SUBAGENTS, type Subagent } from "../../agent-session/acpmux/subagents/subagentFold";
import type { AcpmuxRow } from "../../agent-session/acpmux/model";
import editedReference, { referenceEditRow } from "./editedFilesReference.gallery";

const REPORT =
  "Reviewed the settings corner patch. The clip shape matches the window, the inset is consistent, and all focused corner tests pass.";
const reviewer: Subagent = {
  id: "tour-settings-corner-review",
  parent: null,
  name: "Settings corner review",
  task: "Settings corner review",
  prompt: "Review the corner patch, including the browser clip and the settings window.",
  state: "completed",
  startedAt: minutesAgo(6.8),
  endedAt: minutesAgo(6.1),
  result: REPORT,
};
const chiefMessage =
  "Apply the corner fix, ask a subagent to review it, and keep the changed files available for inspection.";

const edits: AcpmuxRow = {
  ...structuredClone(referenceEditRow),
  id: "tour-nine-file-edits",
  at: minutesAgo(6.9),
  items: referenceEditRow.items?.map((item, index) => ({
    ...item,
    tool: item.tool && { ...item.tool, id: `tour-file-edit-${index}` },
  })),
};

const rows: AcpmuxRow[] = [
  user("Find why the settings window corners look uneven.", 10, { id: "tour-normal-prompt" }),
  assistant("I will compare the shared corner metrics with the browser clip shape.", 9.95, {
    id: "tour-first-commentary",
    assistantPhase: "commentary",
  }),
  activity(
    [
      tool("Read CornerFlush.swift", "read", "completed", {
        id: "tour-read-corners",
        locations: [{ path: "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/CornerFlush.swift" }],
      }),
      tool("Read CEFClipShape.swift", "read", "completed", {
        id: "tour-read-browser",
        locations: [{ path: "Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFClipShape.swift" }],
      }),
    ],
    9.9,
    { id: "tour-read-group" },
  ),
  assistant(
    "The window and browser use different inset calculations. I am checking the existing corner tests before changing either.",
    9.8,
    { id: "tour-second-commentary", assistantPhase: "commentary" },
  ),
  activity(
    [
      tool("Check the corner tests", "execute", "completed", {
        id: "tour-check-command",
        command: "rg -n 'CornerFlush|clipShape' Packages/macOS/CmuxNext/Tests",
        output: "CornerFlushTests.swift:12: shared inset\nCEFClipTests.swift:28: browser clip",
        exitCode: 0,
        startedAt: minutesAgo(9.78),
        endedAt: minutesAgo(9.7),
      }),
    ],
    9.78,
    { id: "tour-command-group" },
  ),
  assistant(
    "**Finding:** the browser clip applies an extra inset.\n\nUse the same corner metrics for both surfaces:\n\n```swift\nlet corners = CornerFlush.metrics(for: window)\n```\n\nThe focused tests cover the shared inset and browser clip. The next step is to apply the patch and review the changed files.",
    9.6,
    { id: "tour-first-final", assistantPhase: "final_answer" },
  ),
  summary(9.6, { id: "tour-first-summary", status: "completed", durationMs: 24_000, toolCount: 3 }),

  user(chiefMessage, 7, {
    id: "tour-chief-message",
    from: "chief",
  }),
  assistant("I will apply the shared metrics and have the corner reviewer check the result.", 6.98, {
    id: "tour-patch-commentary",
    assistantPhase: "commentary",
  }),
  edits,
  row(SUBAGENTS, 6.8, { id: "tour-review-group", subagents: [reviewer] }),
  assistant(
    "The corner patch is ready.\n\n- **9 files changed:** +129 −5.\n- The browser and settings window share their corner metrics.\n- A corner reviewer is checking the patch.\n\nOpen the file card to inspect individual diffs. The reviewer's completion line will keep its report available.",
    6.3,
    { id: "tour-patch-final", assistantPhase: "final_answer" },
  ),
  summary(6.3, { id: "tour-patch-summary", status: "completed", durationMs: 42_000, toolCount: 9 }),

  user("Check the wider layout too, but stop before making any more edits.", 4, { id: "tour-stopped-prompt" }),
  assistant("Checking the wide layout against the same metrics.", 3.95, {
    id: "tour-stopped-commentary",
    assistantPhase: "commentary",
  }),
  activity(
    [
      tool("Check the patch formatting", "execute", "completed", {
        id: "tour-format-command",
        command: "git diff --check",
        output: "",
        exitCode: 0,
        startedAt: minutesAgo(3.9),
        endedAt: minutesAgo(3.8),
      }),
    ],
    3.9,
    { id: "tour-stopped-activity" },
  ),
  summary(3.75, { id: "tour-stopped-summary", status: "cancelled", durationMs: 15_000, toolCount: 1 }),
  user("Continue with the current patch. No additional edits are needed.", 3.5, { id: "tour-continue-prompt" }),
  assistant(
    "Continued with the current patch. The wide layout uses the same inset, and the diff has no whitespace errors.",
    3.3,
    { id: "tour-continued-final", assistantPhase: "final_answer" },
  ),
  summary(3.3, { id: "tour-continued-summary", status: "completed", durationMs: 12_000 }),

  user("Run one final regression check while I inspect the conversation.", 0.9, { id: "tour-live-prompt" }),
  assistant("Running the focused corner check now.", 0.85, {
    id: "tour-live-commentary",
    assistantPhase: "commentary",
  }),
  activity(
    [
      tool("Run the corner regression check", "execute", "in_progress", {
        id: "tour-live-command",
        command: "bun test test/window-corners.test.ts",
        output: "Checking the shared corner metrics…",
        startedAt: minutesAgo(0.8),
      }),
    ],
    0.8,
    { id: "tour-live-activity" },
  ),
].map((item, index) => ({ ...item, seq: index + 1 }));

export default agentPaneEntry({
  id: "agent-pane.parity-full-conversation",
  title: "Full conversation",
  area: "Agent pane",
  height: 760,
  covers: ["agent-session/acpmux/App.tsx"],
  variants: {
    tour: {
      note: "One realistic conversation: expanded work, tool groups, final Markdown, Chief message, nine edited files, subagent completion and report, a stopped and resumed turn, and live Working at the end. Scroll to inspect the whole timeline.",
      experiments: { "live-turn-clock": "top", "subagent-done-report": "compact" },
      snapshot: chat(rows, {
        harness: "codex",
        model: "gpt-6-astra",
        title: "Review the settings window corners",
        isWorking: true,
        subagentViews: {
          [reviewer.id]: [
            user(reviewer.prompt!, 6.8, { id: "tour-child-prompt" }),
            assistant(REPORT, 6.1, { id: "tour-child-report", assistantPhase: "final_answer" }),
          ],
        },
      }),
      native: {
        ...editedReference.variants["nine-files"]!.native,
        "chief.face": { name: "Ops Chief", src: UPLOADED_AVATAR },
      },
      play: async (ctx) => {
        await ctx.scroll({ selector: ".acpmux-scroll" }, "top");
        await ctx.waitFor(() =>
          ctx.document.querySelector('[data-row-id="worked-tour-normal-prompt"] button.cv-worked'),
        );
        const fold = ctx.document.querySelector<HTMLButtonElement>(
          '[data-row-id="worked-tour-normal-prompt"] button.cv-worked',
        )!;
        if (fold.getAttribute("aria-expanded") !== "true")
          await ctx.click({ selector: '[data-row-id="worked-tour-normal-prompt"] button.cv-worked' });
        await ctx.waitFor(
          () =>
            ctx.document
              .querySelector('[data-row-id="worked-tour-normal-prompt"] button.cv-worked')
              ?.getAttribute("aria-expanded") === "true",
        );
        await ctx.scroll({ selector: ".acpmux-scroll" }, "top");
      },
    },
  },
});
