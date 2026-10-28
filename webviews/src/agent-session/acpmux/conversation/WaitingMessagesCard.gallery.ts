// l10n-allow-file: gallery fixtures (sample lane messages and prompts), not shipped UI.
// Several other sessions' messages that wait for the agent, as one card (Leo, 2026-10-27: "i also
// feel like there should be better batching for messages from other sessions so you can get to
// things faster/more efficiently"): steered in and unread ("Read after this step") or queued behind
// the turn ("Read after this turn"), never one card of both. The head is one line: the chevron, how
// many messages from how many sessions, the senders, the delivery note. Open, each message is its
// own received card with its own actions, oldest first (WaitingMessagesCard.tsx,
// waitingMessages.ts). The head's look: A, the count and the senders' names, ships; B (the count
// alone) and C (the senders as hairline chips) are drawn here only, over the shipped card.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";

const LANES: [string, string][] = [
  ["composer-caret", "Merged #24210; the caret keeps its place after paste."],
  ["sidebar-cleanup", "**Review passed** on #24214. Its only red is the gallery scope menu, red on base too."],
  ["grid-fix", "Grid reserves its height before images load; tests pass on cmux/grid-fix."],
  ["pr-owner-reviewers", "Reviewer assigned on #24221; nothing needs you."],
  ["fleet-hygiene", "Cleared 41 GB of stale DerivedData on the minis."],
  ["nightly-next", "Nightly published at 3b01de6, 12 minutes after the landing."],
  ["menu-instant", "All composer menus open on the click now; closing still fades."],
  ["l10n-sweep", "Filled 14 missing keys across 21 locales."],
  ["subsession-card", "Sub-session cards read their state from one store now."],
  ["review-astra", "VERDICT: SHIP on #24230 at 9e09de9."],
  ["coord-deputy", "Rebase onto #24233 before you push: it moves the queue rows."],
];
const queued = LANES.map(([name, text], index) => ({
  id: `a${index + 1}`,
  prompt: text,
  message: { name, sessionId: `lane-${index + 1}`, text, raw: text },
}));
const own = { id: "p1", prompt: "Then add a test for the 429 path" };
const running = [
  user("Split the retry work into lanes and report back", 9),
  assistant("Started the lanes; they will message this chat.", 8.5),
  summary(8.5, { status: "completed" }),
  user("Add retries to the fetch helper", 1),
  assistant("Reading the helper…", 0.5, { streaming: true }),
];
/// Another session's message steered into the running turn that the agent has not read yet.
const steered = (index: number, [name, text]: [string, string], sessionId = name): AcpmuxRow =>
  user(text, 0.4 - index * 0.05, {
    id: `steer-${index}`,
    incoming: { kind: "message", message: { name, sessionId, text, raw: text } },
    untyped: true,
    steer: "waiting",
    steerPromptId: `p-steer-${index}`,
  });
// Four from three sessions: the first lane wrote twice.
const steers = [LANES[0]!, LANES[9]!, LANES[0]!, LANES[10]!].map((lane, index) => steered(index, lane));
const stepping = chat([...running, ...steers], { isWorking: true, waitingSteers: steers.map((row) => row.id) });
const elevenAndMine = chat(running, { isWorking: true, queue: [...queued, own] });
const MINIMAL = { "sidebar.minimal": true };

const open: Play = async (ctx) => {
  await ctx.click({ selector: ".cv-waiting__toggle" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-waiting[data-open] .cv-received"));
};

const ALT_ID = "waiting-head-alt";
/// Draws a gallery-only head over the shipped one: its stylesheet.
const alternate =
  (css: string): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector(".cv-waiting"));
    ctx.document.getElementById(ALT_ID)?.remove();
    const style = ctx.document.createElement("style");
    style.id = ALT_ID;
    style.textContent = css;
    ctx.document.head.append(style);
  };
/// B: the count alone; the names only once it opens.
const countOnly = alternate(`.cv-waiting__senders { display: none; }`);
/// C: each sender a hairline chip.
const chips = alternate(`.cv-waiting__senders { display: inline-flex; gap: 4px; }
.cv-waiting__sender + .cv-waiting__sender::before { content: none; }
.cv-waiting__sender { padding: 0 6px; height: 16px; line-height: 16px; border-radius: 8px;
  box-shadow: inset 0 0 0 var(--cmux-hairline, 0.5px) color-mix(in srgb, var(--cv-text) 30%, transparent); }`);

export default agentPaneEntry({
  id: "agent-pane.waiting-messages-card",
  title: "Waiting messages from other sessions, as one card",
  area: "Agent pane",
  height: 760,
  covers: [
    "agent-session/acpmux/conversation/WaitingMessagesCard.tsx",
    "agent-session/acpmux/conversation/waitingMessages.ts",
  ],
  variants: {
    step: {
      note: "Four messages from three sessions steered into the running turn, none read yet: one card, 4 messages from 3 sessions, the senders, Read after this step (A, shipped).",
      snapshot: stepping,
    },
    "step-open": {
      note: "Play: the card opened: each message is its received card with Read after this step and its own Send now, oldest first.",
      snapshot: stepping,
      play: open,
    },
    turn: {
      note: "Eleven sessions' messages and one prompt of the person's wait for the running turn: one card with Read after this turn; the composer's queue is the person's one prompt.",
      snapshot: elevenAndMine,
    },
    "turn-three": {
      note: "Three sessions' messages wait for the running turn: one card, the whole chat on one screen.",
      snapshot: chat(running, { isWorking: true, queue: queued.slice(0, 3) }),
    },
    "turn-open": {
      note: "Play: the queued card opened: every message is its received card, each with its own ⋯ menu.",
      snapshot: elevenAndMine,
      play: open,
    },
    minimal: {
      note: "The steered card in Minimal Mode: the same one line.",
      display: MINIMAL,
      snapshot: stepping,
    },
    "count-only": {
      note: "Gallery only (B): the count alone, no names.",
      snapshot: stepping,
      play: countOnly,
    },
    chips: {
      note: "Gallery only (C): each sender a hairline chip.",
      snapshot: stepping,
      play: chips,
    },
    single: {
      note: "One steered message alone draws as before: its received card, no group.",
      snapshot: chat([...running, steered(0, LANES[3]!)], { isWorking: true }),
    },
  },
});
