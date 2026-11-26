// l10n-allow-file: gallery fixtures (sample prompts, paths, commands and subagent names), not shipped UI.
// Chat cards at narrow widths (Leo 2026-11-22: "overlapping text via the buttosn when the pane is
// small. ok, so simply prepare for this scenario beforehand and lay things out better. below the
// potentially long text, etc. or make the thing bigger. whatever. and be able to shrink down to
// icons."). Each variant puts a card with long text and trailing buttons in the agent pane, and its
// play checks the geometry with cardFitProblems: no text run under a button, no button over another,
// nothing past the card's right edge. The layout rule is conversation/cardFit.css;
// test/chat-card-fit.test.ts plays every variant at 240, 320, 420 and 640 px, and runs the same
// check over the other cards' own gallery entries.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { recentRun, minutesAgo } from "../../gallery/clock";
import { activity, assistant, chat, CWD, row, summary, tool, user } from "../../gallery/fixtures/acpmux";
import type { AcpmuxPermission } from "./model";
import { SUBAGENTS, type Subagent } from "./subagents/subagentFold";
import { cardFitProblems } from "./cardFitCheck";

// --- Fixtures -----------------------------------------------------------------------------------

type Edit = { path: string; oldText?: string; newText: string };

const LONG_NAME: Edit = {
  path: `${CWD}/docs/handbook/ios-target-is-cmux-internal.md`,
  oldText: "",
  newText: Array.from({ length: 14 }, (_, line) => `Line ${line + 1} of the note.`).join("\n") + "\n",
};
const MANY: Edit[] = [
  {
    path: `${CWD}/src/agent-session/acpmux/conversation/turnChanges/editedFilesSettingsPanel.tsx`,
    oldText: "export const rows = 3;\n",
    newText: 'export const rows = 5;\nexport const scope = "turn";\n',
  },
  {
    path: `${CWD}/src/net/backoff/policy/jitter/exponentialWithDecorrelatedJitter.ts`,
    newText: "export const tries = 3;\n",
  },
  {
    path: `${CWD}/test/net/backoff/exponentialWithDecorrelatedJitter.test.ts`,
    oldText: "",
    newText: 'test("tries", () => expect(3).toBe(3));\n',
  },
];

/// One finished turn that wrote `files` with whole-text edits at absolute paths (turnChanges/model.ts
/// fileUndo takes nothing else), so its card offers Undo; the card names them relative to CWD.
function turn(files: Edit[], prompt: string) {
  return chat([
    user(prompt, 6),
    activity(
      files.map((file) => tool(`Edit ${file.path.slice(CWD.length + 1)}`, "edit", "completed", { diffs: [file] })),
      5.9,
    ),
    assistant("Done.", 5.2),
    summary(5.2, { status: "completed", toolCount: files.length }),
  ]);
}

const ASK: AcpmuxPermission = {
  permissionId: "card-fit-ask",
  title: "Run bun run check:all --filter agent-session/acpmux/conversation/turnChanges",
  kind: "execute",
  command: "bun run check:all --filter agent-session/acpmux/conversation/turnChanges --reporter=verbose",
  rule: "Bash(bun run check:all:*)",
  pending: true,
  options: [
    { id: "allow_once", name: "Allow", kind: "allow_once", allow: true },
    { id: "allow_always", name: "Always allow", kind: "allow_always", allow: true },
    { id: "reject_once", name: "Deny", kind: "reject_once", allow: false },
  ],
};

function agent(name: string, state: Subagent["state"], minutes: number): Subagent {
  return {
    id: `agent-${name.toLowerCase().replaceAll(" ", "-")}`,
    parent: null,
    name,
    task: name,
    kind: "general-purpose",
    state,
    ...(state === "running" ? { startedAt: minutesAgo(minutes) } : recentRun(minutes, 1.4)),
  };
}

// --- Plays --------------------------------------------------------------------------------------

/// Waits for `selector`, rests the pointer on the composer (the step the report records) and checks
/// every card on the page.
const check =
  (selector: string): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector(selector), { capMs: 5000 });
    await ctx.hover({ selector: ".acpmux-composer-box" });
    const problems = cardFitProblems(ctx.document);
    if (problems.length) throw new Error(problems.join("; "));
  };

const openTray: Play = async (ctx) => {
  await ctx.waitFor(() =>
    ctx.document.querySelector(".acpmux-running-tray .acpmux-agent-line, .acpmux-running-tray__head"),
  );
  const head = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
  if (head && head.getAttribute("aria-expanded") !== "true")
    await ctx.click({ selector: ".acpmux-running-tray__head" });
  await check(".acpmux-agent-line")(ctx);
};

const variants: Record<string, AgentPaneVariant> = {
  "edited-long-name": {
    note: "One new file with a long name, the turn ended: Edited ios-target-is-cmux-internal.md +14 -0 and Undo.",
    snapshot: turn([LONG_NAME], "Write down that the iOS target is cmux-internal"),
    play: check(".acpmux-edited"),
  },
  "edited-many": {
    note: "Three files with long paths: the rows and the card's actions.",
    height: 560,
    snapshot: turn(MANY, "Make the edited-files rows a setting"),
    play: check(".acpmux-edited"),
  },
  "edited-diff-open": {
    note: "Play: click the card's head; its diff opens inline inside the card.",
    height: 640,
    snapshot: turn([LONG_NAME], "Write down that the iOS target is cmux-internal"),
    play: async (ctx) => {
      await ctx.waitFor(() => ctx.document.querySelector(".acpmux-edited-head"));
      await ctx.click({ selector: ".acpmux-edited-head" });
      // The click is the step; the check reads the card once its diff has drawn.
      await ctx.waitFor(() => ctx.document.querySelector(".acpmux-edited .acpmux-edited-stack .cv-edit-diff"), {
        capMs: 5000,
      });
      const problems = cardFitProblems(ctx.document);
      if (problems.length) throw new Error(problems.join("; "));
    },
  },
  permission: {
    note: "A pending command ask with a long title and rule: Deny, Always allow and Allow.",
    height: 560,
    snapshot: chat(
      [user("Run the turn-changes checks", 2), assistant("I want to run the turnChanges checks next.", 1)],
      { permission: ASK, isWorking: true },
    ),
    play: check(".acpmux-permission-card"),
  },
  subagent: {
    note: "Play: open the tray; a subagent with a long task beside its time and chevron.",
    checks: {
      layoutShiftMax: {
        value: 0.01,
        reason: "Opening the tray grows it upward over the composer: the dock moves once, by the tray's height.",
      },
    },
    height: 480,
    snapshot: chat(
      [
        user("Review the tray and audit the stack", 4),
        row(SUBAGENTS, 3, {
          subagents: [
            agent("Review the subagent tray row and the composer hat's done check at narrow widths", "running", 2),
            agent("Audit the stack", "completed", 3),
          ],
        }),
      ],
      { isWorking: true },
    ),
    play: openTray,
  },
};

export default agentPaneEntry({
  id: "agent-pane.card-fit",
  title: "Chat cards at narrow widths",
  area: "Agent pane",
  height: 480,
  widths: { narrow: 240, normal: 320, wide: 640 },
  covers: [
    "agent-session/acpmux/conversation/cardFit.css",
    "agent-session/acpmux/conversation/EditedFilesCard.tsx#EditedFilesCard",
    "agent-session/acpmux/PermissionCard.tsx#PermissionCard",
    "agent-session/acpmux/subagents/AgentLine.tsx",
  ],
  variants,
});
