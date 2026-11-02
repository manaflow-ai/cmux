// l10n-allow-file: gallery fixtures (sample prompts, thoughts, commands and replies), not shipped UI.
// A turn organized as Claude Code desktop draws one (Leo, 2026-10-29: "we want to have that
// capabilitiy of rendering like claude code desktop has stuff organized."): a paragraph, a
// question asked and answered (the answered QuestionCard), a plan of three steps, then a thought
// and five shell steps under "Ran 5 commands", opened, and the prose after them. Drawn through the
// real transcript (TurnRows.tsx, ToolGroupRow.tsx), so the step bodies and the question and plan
// cards show here as they change. The arms are the opened group's looks
// (`data-tool-steps-look`, conversation.css `.cv-steps`): card (the default), tree and zebra.
import answeredCollapsed from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/answered-collapsed.json";
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity, AcpmuxPlanEntry } from "../model";
import type { AgentQuestion } from "../question/model";
import { QUESTION_RECORD } from "../question/record";

const MINUTE = 60_000;
const at = (minutes: number) => Date.UTC(2026, 9, 29, 9, 0, 0) + minutes * MINUTE;

/// A finished shell step with Claude's Bash description, its command and what it printed.
const step = (description: string, command: string, output: string, minute: number, exitCode = 0): AcpmuxActivity =>
  tool(command, "execute", "completed", {
    description,
    command,
    output,
    exitCode,
    startedAt: at(minute),
    endedAt: at(minute) + 1_400,
  });

const todo = (content: string, status: AcpmuxPlanEntry["status"]): AcpmuxPlanEntry => ({ content, status });

const LEAD =
  "The fetch helper retries every failure the same way, so a 404 waits through three backoffs before it fails. " +
  "I should read how the helper decides to retry, find who calls it, and check whether the tests already cover a client error.\n\n" +
  "If the retry loop has no status check, the fix belongs there rather than in each caller.";

function turn() {
  return [
    user("Make the fetch helper stop retrying client errors", 9),
    assistant(
      "The helper lives in `src/net/fetchWithRetry.ts` and every network call in the app goes through it. " +
        "Before I change how it retries, one question about authentication, since the retry rules differ for it.",
      8.8,
    ),
    row(QUESTION_RECORD, 8.6, { question: answeredCollapsed as unknown as AgentQuestion }),
    row("plan", 8.4, {
      plan: [
        todo("Find where the helper decides to retry", "completed"),
        todo("Stop retrying 4xx responses", "in_progress"),
        todo("Cover it with a test", "pending"),
      ],
    }),
    activity(
      [
        thought(LEAD, { startedAt: at(1), endedAt: at(1) + 6_000 }),
        step(
          "Found the retry loop and its status check",
          "rg -n 'retry' src/net/fetchWithRetry.ts",
          "12:export async function fetchWithRetry(url, options = {}) {\n18:  for (let attempt = 0; attempt < retries; attempt++) {\n24:    if (!response.ok) await delay(backoff(attempt));\n",
          2,
        ),
        step(
          "Listed every caller of fetchWithRetry",
          "rg -l fetchWithRetry src",
          "src/net/fetchWithRetry.ts\nsrc/api/orders.ts\nsrc/api/profile.ts\nsrc/api/search.ts\n",
          3,
        ),
        thought(
          "None of the callers handle a 404 themselves, so a client error waiting through every backoff is what the reader sees as a slow page. The check belongs in the loop.",
          { startedAt: at(4), endedAt: at(4) + 3_000 },
        ),
        step(
          "Read the retry tests",
          "sed -n '1,60p' src/net/fetchWithRetry.test.ts",
          "describe('fetchWithRetry', () => {\n  it('retries a 503 three times', async () => {\n",
          5,
        ),
        step("Ran the retry tests before the change", "bun test src/net", "3 pass\n0 fail\n", 6),
        step("Checked the branch is clean", "git status --short", "", 7),
      ],
      8.2,
      { id: "organization-run" },
    ),
    assistant(
      "The loop retries any response that isn't ok. I'll stop it at 4xx statuses other than 408 and 429, which are worth another try, then add a test for a 404.",
      7.8,
    ),
    summary(7.7, { status: "completed", durationMs: 78_000, toolCount: 5 }),
  ];
}

/// Opens the ended turn's "Worked for" line, then "Ran 5 commands", as the reference shows it.
const openRun: Play = async (ctx) => {
  const worked = () => ctx.document.querySelector<HTMLElement>(".cv-worked");
  await ctx.waitFor(() => worked() ?? ctx.document.querySelector(".cv-tool[aria-expanded]"), { capMs: 10_000 });
  if (worked()?.getAttribute("aria-expanded") === "false") {
    await ctx.click({ selector: ".cv-worked" });
    await ctx.waitFor(() => worked()?.getAttribute("aria-expanded") === "true", { capMs: 10_000 });
  }
  const line = () =>
    [...ctx.document.querySelectorAll<HTMLButtonElement>("button.cv-tool[aria-expanded]")].find((node) =>
      /5/.test(node.textContent ?? ""),
    );
  await ctx.waitFor(line, { capMs: 10_000 });
  if (line()?.getAttribute("aria-expanded") === "false") await ctx.click({ role: "button", name: /5/ });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-steps"), { capMs: 10_000 });
};

const variant = (look: "card" | "tree" | "zebra", note: string): AgentPaneVariant => ({
  note,
  snapshot: chat(turn(), { title: "Stop retrying client errors" }),
  documentAttributes: { "data-tool-steps-look": look },
  play: openRun,
});

export default agentPaneEntry({
  id: "agent-pane.claude-desktop-organization",
  title: "Claude desktop organization",
  area: "Agent pane",
  height: 900,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: [
    "agent-session/acpmux/conversation/ToolGroupRow.tsx",
    "agent-session/acpmux/conversation/ThoughtRow.tsx#StepThought",
    "agent-session/acpmux/conversation/toolGroups.ts",
  ],
  variants: {
    card: variant(
      "card",
      "Selected default: one rounded group in the cards' ring; the leading thought in full, then a row per step with its disclosure right after its words, hairlines between.",
    ),
    tree: variant("tree", "Alternative: the earlier tree guide with the glyphs back, hairlines between steps."),
    zebra: variant("zebra", "Alternative: no ring or hairlines; every other step on the cards' fill."),
  },
});
