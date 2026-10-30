// l10n-allow-file: gallery fixtures (sample lane messages and prompts), not shipped UI.
// Another agent's message that waits for the running turn (Leo, 2026-10-25: "I don't know why these
// things are queued up. It's kind of strange."): no composer-queue row. The transcript draws the
// waiting messages as one collapsed group, "N messages from M sessions" (PendingMessagesCard.tsx),
// each a compact received line when opened, with no "Read after this turn" (Leo, 2026-10-29: "why
// the fuck do you guys keep doing this fucking bullshit with the red after this turn?"). A line's ⋯
// menu is a message's: Send now, Copy, Dismiss (QueuedMessageCard.tsx). A sub-session's note to its
// parent through acpmux's outbox reads the same, its "From <name>:" taken for its sender (Leo,
// 2026-10-29: "why is this styled like this?").
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { queuedMessage } from "../direct";

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
const elevenAndMine = chat(running, { isWorking: true, queue: [...queued, own] });
/// The person stopped the turn: acpmux holds the agents' messages (`queue_paused` with
/// `reason: "stop"`) until their next turn completes, and the stopped turn offers Continue.
const stopped = [...running.slice(0, 4), assistant("Reading the helper…", 0.5), summary(0.4, { status: "cancelled" })];
const heldByStop = chat(stopped, {
  isWorking: false,
  queue: queued.slice(0, 3).map((entry) => ({ ...entry, heldByStop: true as const })),
});
const MINIMAL = { "sidebar.minimal": true };
/// A sub-session's note to its parent as acpmux's outbox records it (`acpmux send --no-wait`): no
/// provenance, its sender only in its "From <name>:" lead.
const OUTBOX_TEXT = "From claude-sr2/ui-think-tank: merged https://github.com/teamleaderleo/leo-workspace/pull/1234";
const outboxNote = {
  id: "a-outbox",
  prompt: OUTBOX_TEXT,
  message: queuedMessage({ text: OUTBOX_TEXT, client: "acpmux-outbox#7", promptId: "a-outbox" })!,
};

/// Opens the group of waiting messages, which shows collapsed.
const openGroup: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-pending__toggle"));
  ctx.document.querySelector<HTMLButtonElement>(".cv-pending__toggle")!.click();
  await ctx.waitFor(() => ctx.document.querySelector(".cv-received__from"));
};

export default agentPaneEntry({
  id: "agent-pane.queued-agent-messages",
  title: "Queued messages from other agents",
  area: "Agent pane",
  height: 760,
  covers: [
    "agent-session/acpmux/conversation/QueuedMessageCard.tsx",
    "agent-session/acpmux/conversation/queuedMessages.ts",
    "agent-session/acpmux/ComposerQueue.tsx",
    "agent-session/acpmux/conversation/PendingMessagesCard.tsx",
    "agent-session/acpmux/conversation/incomingMessage.ts",
  ],
  variants: {
    eleven: {
      note: "Eleven agents' messages and one prompt of the person's wait for the running turn: the messages are one collapsed group after the turn, with no Read after this turn; the composer's queue is the person's one prompt, with no fold.",
      snapshot: elevenAndMine,
    },
    "eleven-minimal": {
      note: "The same in Minimal Mode.",
      display: MINIMAL,
      snapshot: elevenAndMine,
    },
    "subsession-outbox": {
      note: "A sub-session's note to its parent through acpmux's outbox: the same compact line as the other agents' messages, its name first, no From prefix, the pull request as owner/repo#N.",
      snapshot: chat(running, { isWorking: true, queue: [outboxNote, queued[0]!, own] }),
      play: async (ctx) => {
        await openGroup(ctx);
      },
    },
    "held-by-stop": {
      note: "The person stopped the turn: three agents' messages wait, held by the Stop, and the first says so and what lets them in (Continue on the stopped turn, or the person's next message), not Read after this turn.",
      snapshot: heldByStop,
    },
    menu: {
      note: "Play: a waiting message's ⋯ menu: Send now, Copy, Dismiss; never the person's queue actions.",
      snapshot: chat(running, { isWorking: true, queue: [queued[10]!, own] }),
      play: async (ctx) => {
        await openGroup(ctx);
        await ctx.hover({ selector: ".cv-received > .cv-disclosure__line" });
        await ctx.waitFor(() => ctx.document.querySelector('[data-menu="waiting-message"]'));
        ctx.document.querySelector<HTMLButtonElement>('[data-menu="waiting-message"]')!.click();
        await ctx.waitFor(() => ctx.document.querySelectorAll('[role="menuitem"]').length >= 2);
      },
    },
    "steer-waiting": {
      note: "A message an agent steered into the running turn that the agent has not read yet: its received line, no Read after this step; Send now is in its ⋯ menu. No spinner row.",
      snapshot: chat(
        [
          ...running,
          user("Reply with only: OK", 0.2, {
            incoming: {
              kind: "message",
              message: {
                name: "pr-owner-reviewers",
                sessionId: "lane-4",
                text: "Reply with only: OK",
                raw: "Reply with only: OK",
              },
            },
            untyped: true,
            steer: "waiting",
            steerPromptId: "p-steer",
          }),
        ],
        { isWorking: true },
      ),
    },
  },
});
