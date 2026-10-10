// l10n-allow-file: gallery fixtures (sample chats, file paths, section titles and rows), not shipped UI.
// The chat summary panel (PINNED-SUMMARY P1'-P6, bead cx-70qp): the header button opens it and it stays open
// until the user closes it (the button, its close button, or Escape inside it). A wide pane docks it as a
// right column beside the transcript; a narrow one as a strip above it. No popover anywhere. Design A
// (Claude) of the pinned summary vote. Behavior proof is in the play steps (no unit tests).
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

/// Opens the panel with the header button, as a user does (the open state then lasts until closed).
export const openPanel = async (ctx: PlayContext) => {
  if (!ctx.document.querySelector("[data-summary-panel]")) await ctx.click({ selector: "[data-summary-toggle]" });
  await ctx.waitFor(() => ctx.document.querySelector("[data-summary-panel]"));
};

/// Closes it again, so the next variant starts closed (the open state is stored per user).
const closePanel = async (ctx: PlayContext) => {
  if (ctx.document.querySelector("[data-summary-panel]")) await ctx.click({ selector: "[data-summary-toggle]" });
  await ctx.waitFor(() => !ctx.document.querySelector("[data-summary-panel]"));
};

export default agentPaneEntry({
  id: "agent-pane.pinned-summary",
  title: "Pinned summary",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 560, normal: 1100, wide: 1280 },
  covers: [
    "agent-session/acpmux/summary/PinnedSummaryCard.tsx#SummaryDock",
    "agent-session/acpmux/summary/SummaryPanel.tsx#SummaryPanel",
    "agent-session/acpmux/summary/SummaryButton.tsx#SummaryButton",
  ],
  variants: {
    "pinned-wide": {
      note: "Wide pane, opened: the panel is a right column beside the transcript (project, Changes, Plan, Outputs, Sources, Pull requests); the transcript narrows, nothing is covered.",
      snapshot: chat(work, { title: "Retry the fetch helper" }),
      play: openPanel,
    },
    "narrow-popover": {
      note: "Narrow pane (use width=narrow), opened: the same panel docks as a strip above the transcript with its own scroll. No popover.",
      snapshot: chat(work, { title: "Retry the fetch helper" }),
      play: openPanel,
    },
    "stays-open": {
      note: "Opened, then a click in the transcript, a scroll and a typed key: the panel is still open (only the button, its close button or Escape inside it close it).",
      snapshot: chat(work, { title: "Retry the fetch helper" }),
      play: async (ctx) => {
        await openPanel(ctx);
        await ctx.click({ selector: ".acpmux-scroll" });
        await ctx.scroll({ selector: ".acpmux-scroll" }, "top");
        await ctx.press("a");
        await ctx.waitFor(() => ctx.document.querySelector("[data-summary-panel]"));
      },
    },
    close: {
      note: "Opened, then Escape inside the panel: it closes and the header button has the focus.",
      snapshot: chat(work, { title: "Retry the fetch helper" }),
      play: async (ctx) => {
        await openPanel(ctx);
        await ctx.focus({ selector: "[data-summary-close]" });
        await ctx.press("Escape");
        await ctx.waitFor(
          () =>
            !ctx.document.querySelector("[data-summary-panel]") &&
            ctx.document.activeElement?.hasAttribute("data-summary-toggle"),
        );
      },
    },
    empty: {
      note: "A new chat, opened: Changes, Outputs, Subagents and Sources read None.",
      snapshot: chat([user("Look around the repo", 1)], { title: "Look around" }),
      play: openPanel,
    },
    busy: {
      note: "Many pull requests and sources, opened: five rows each, then View all.",
      snapshot: chat(busy, { title: "Land the scroll fixes" }),
      play: async (ctx) => {
        await openPanel(ctx);
        await closePanel(ctx);
        await openPanel(ctx);
      },
    },
  },
});
