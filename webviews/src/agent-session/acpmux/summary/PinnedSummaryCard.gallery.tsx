// l10n-allow-file: gallery fixtures (sample chats, file paths, section titles and rows), not shipped UI.
// The chat summary, pinned (PINNED-SUMMARY P1-P6, the Codex app's card) and as the header popover in
// a narrow pane; and custom sections (S1) from the user's config and from the chat's agent, with
// a failed provider. Design A (Claude) of the pinned summary vote.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { activity, assistant, chat, CWD, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";

const edit = (path: string, newText: string) =>
  tool("Write", "edit", "completed", { diffs: [{ path: `${CWD}/${path}`, newText }] });
const pr = (number: number, title: string) =>
  tool(`gh pr create`, "execute", "completed", {
    command: `gh pr create --title "${title}"`,
    output: `https://github.com/acme/atlas-web/pull/${number}`,
    exitCode: 0,
  });
const fetch = (url: string) => tool(`Fetch ${url}`, "fetch", "completed", { inputSummary: url });
const plan = (minutes: number) =>
  row("plan", minutes, {
    text: JSON.stringify([
      { content: "Read the retry helper and its tests", status: "completed" },
      { content: "Add backoff with jitter to GET requests", status: "in_progress" },
      { content: "Document the POST policy", status: "pending" },
    ]),
  });

export const work: AcpmuxRow[] = [
  user("Add retries with backoff to the fetch helper", 12),
  plan(11.5),
  activity(
    [
      fetch("https://developer.mozilla.org/en-US/docs/Web/API/AbortController"),
      edit("src/net/fetch.ts", "export const retries = 3;\n"),
      edit("src/net/fetch.test.ts", "test('retries', () => {});\n"),
      pr(412, "Retry GETs with backoff"),
    ],
    10,
  ),
  assistant("GETs retry with backoff and jitter; POSTs only with a policy. PR #412 is open.", 9),
  summary(9, { status: "completed", toolCount: 4 }),
];

const busy: AcpmuxRow[] = [
  user("Land the scroll fixes across the four repos", 30),
  activity(
    [
      ...Array.from({ length: 9 }, (_, index) => pr(500 + index, `Scroll fix part ${index + 1}`)),
      ...Array.from({ length: 8 }, (_, index) => fetch(`https://github.com/acme/atlas-web/issues/${700 + index}`)),
      ...Array.from({ length: 7 }, (_, index) => edit(`src/scroll/part${index}.ts`, "x\n")),
    ],
    25,
  ),
  assistant("Nine pull requests are open; the list shows five, View all shows the rest.", 20),
  summary(20, { status: "completed", toolCount: 24 }),
];

const openSummary = async (ctx: PlayContext) => {
  await ctx.click({ selector: ".acpmux-summary-button" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-summary-popover"));
};

export default agentPaneEntry({
  id: "agent-pane.pinned-summary",
  title: "Pinned summary",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 560, normal: 1100, wide: 1280 },
  covers: [
    "agent-session/acpmux/summary/PinnedSummaryCard.tsx#PinnedSummaryCard",
    "agent-session/acpmux/summary/SummaryPanel.tsx#SummaryPanel",
    "agent-session/acpmux/summary/SummaryButton.tsx#SummaryButton",
  ],
  variants: {
    "pinned-wide": {
      note: "A wide pane: the card is pinned at the top right (project, Changes, Plan, Outputs, Sources, Pull requests).",
      snapshot: chat(work, { title: "Retry the fetch helper" }),
    },
    "narrow-popover": {
      note: "A narrow pane: no card; the header button opens the same content as a popover. Use width=narrow.",
      snapshot: chat(work, { title: "Retry the fetch helper" }),
      play: openSummary,
    },
    empty: {
      note: "A new chat: Changes, Outputs, Subagents and Sources read None.",
      snapshot: chat([user("Look around the repo", 1)], { title: "Look around" }),
    },
    busy: {
      note: "Many pull requests and sources: five rows each, then View all.",
      snapshot: chat(busy, { title: "Land the scroll fixes" }),
    },
  },
});
