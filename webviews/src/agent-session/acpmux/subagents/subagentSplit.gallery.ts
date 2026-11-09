// l10n-allow-file: gallery fixtures (a sample prompt and subagent names), not shipped UI.
// A subagent opened from its chat goes to the right split (Leo, 2026-11-02: "WHEN I OPEN A SUBAGENT
// IT SHOULD GO TO THE RIGHT SPLIT AREA"; #32677). The two panes as the app shows them: `parent`, the
// chat on the left with its subagents' line and each one's state and Session Info open; `child`, the
// pane the app opens on the right on one subagent (a `subagent:` reveal). The child pane shows the
// subagent's task (never a raw id), its own transcript, and Session Info closed: a pane opened in a
// split does not inherit it (Leo, 2026-11-03: "like if they want it open they can just do it on the
// right split one but otherwise it really doesn't have that much space pretty often"; #32763).
// subagentSplitPair.gallery.tsx draws the two side by side.
import { agentPaneEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { activity, assistant, chat, row, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";

export const SPLIT_ENTRY = "agent-pane.subagent-split";
const REVIEW = "agent-review-october";
const UUID = /[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/iu;

const agent = (id: string, name: string, state: Subagent["state"], fields: Partial<Subagent> = {}): Subagent => ({
  id,
  parent: null,
  name,
  task: name,
  state,
  startedAt: minutesAgo(4),
  ...(state !== "running" && { endedAt: minutesAgo(2) }),
  ...fields,
});

const snapshot = {
  ...chat(
    [
      user("Review the October engineering work and summarize what shipped", 5),
      row(SUBAGENTS, 4, {
        subagents: [
          agent(REVIEW, "Review October engineering work", "running", { action: "Read the merged PR list" }),
          agent("agent-release-notes", "Draft the release notes", "completed"),
        ],
      }),
    ],
    { isWorking: true, title: "October engineering review" },
  ),
  subagentViews: {
    [REVIEW]: [
      activity(
        [
          thought("Which pull requests merged in October?"),
          tool("Search merged pull requests", "search", "completed"),
          tool("Read CHANGELOG.md", "read", "completed"),
        ],
        3.6,
        { id: `${REVIEW}:activity-1` },
      ),
      assistant("Forty-two pull requests merged; the largest were the pane layout and the Cloud machines.", 3, {
        id: `${REVIEW}:assistant-2`,
      }),
    ],
  },
};

const native = { "pane.tabState": { inspector: true } };
const shownPanel = ".acpmux-session-info[data-presence='shown']";

/// The left pane: the chat with Session Info open, its running subagent in the tray and its done one in
/// the transcript.
async function parent(ctx: PlayContext) {
  const { setSessionInfoOpen } = await import("../session-info/sessionInfoState");
  setSessionInfoOpen(true);
  // A pane too narrow for a readable chat beside the panel (the left half of the pair,
  // subagentSplitPair.gallery.tsx) keeps a saved open state closed until the toggle opens it
  // (session-info/SessionInfoNarrowPane.gallery.tsx); a wide one has it open already.
  const closed = 'button.acpmux-session-info-toggle[aria-pressed="false"]';
  await ctx.waitFor(() => ctx.document.querySelector("button.acpmux-session-info-toggle"));
  if (!ctx.document.querySelector(shownPanel) && ctx.document.querySelector(closed))
    await ctx.click({ selector: closed });
  await ctx.waitFor(() => ctx.document.querySelector(shownPanel));
  // The running tray (the default) lists the running subagent; the done one is a line in the transcript.
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray"));
  await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-done"));
}

/// The right pane: the app opened it on the subagent. Its task names it, its own rows show, and
/// Session Info stays closed though the parent's is open.
async function child(ctx: PlayContext) {
  const page = ctx.document.defaultView as unknown as { cmuxAcpmuxBridge?: { revealTurn?(id: string): void } };
  page.cmuxAcpmuxBridge?.revealTurn?.(`subagent:${REVIEW}`);
  await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-of__task"));
  const title = ctx.find({ selector: ".cv-subagent-of" }).textContent ?? "";
  if (!title.includes("Review October engineering work")) throw new Error(`the child pane is not titled: ${title}`);
  if (UUID.test(title) || title.includes(REVIEW)) throw new Error(`the child pane shows a raw id: ${title}`);
  await ctx.waitFor(() => ctx.document.body.textContent?.includes("Forty-two pull requests merged"));
  await ctx.waitFor(() => !ctx.document.querySelector(shownPanel));
}

export default agentPaneEntry({
  // A literal, as every entry's id: test/support/galleryFrame.ts finds an entry's file by its
  // `id: "<id>"` line, and an id read from a constant matched no file (gallery-control-surfaces).
  id: "agent-pane.subagent-split",
  title: "Subagent opened in the right split",
  area: "Agent pane",
  height: 640,
  covers: [
    "agent-session/acpmux/subagents/SubagentGroup.tsx#SubagentOfRow",
    "agent-session/acpmux/subagents/SubagentComposer.tsx#SubagentComposer",
  ],
  keywords: ["subagent", "split", "right", "task", "session info"],
  variants: {
    parent: {
      note: "The chat on the left: its subagents' line with each one's state (one running, one done), Session Info open.",
      snapshot,
      native,
      play: parent,
    },
    child: {
      note: "The pane the app opens on the right on the running subagent: its task as the title (never a raw id), its own transcript, Session Info closed.",
      snapshot,
      native,
      play: child,
    },
  },
});
