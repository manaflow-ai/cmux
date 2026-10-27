// l10n-allow-file: gallery fixtures (sample lane messages and prompts), not shipped UI.
// Another agent's message that waits for the running turn (Leo, 2026-10-25: "I don't know why these
// things are queued up. It's kind of strange."): no composer-queue row. The transcript draws it at
// once as its received card after the turn, with a quiet "Read after this turn" at the line's end
// and its actions (Steer, Edit message, queueing, Delete) in the card's ⋯ menu
// (QueuedMessageCard.tsx, queuedMessages.ts). The composer's queue, its fold and its count, hold the
// person's own prompts only. A steer the agent has not read yet reads the same, "after this step".
// The note's look: A, plain dim caption text, ships; B (a clock and "After this turn") and C (a
// hairline "Queued" pill) are drawn here only, over the shipped note.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

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
const MINIMAL = { "sidebar.minimal": true };

const ALT_ID = "queued-note-alt";
/// Draws a gallery-only note over the shipped one: its stylesheet, then `mark` on each note.
const alternate =
  (css: string, mark: (note: HTMLElement) => void): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-received__queued").length >= LANES.length);
    ctx.document.getElementById(ALT_ID)?.remove();
    const style = ctx.document.createElement("style");
    style.id = ALT_ID;
    style.textContent = css;
    ctx.document.head.append(style);
    ctx.document.querySelectorAll<HTMLElement>(".cv-received__queued").forEach(mark);
  };
const CLOCK =
  '<svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.3" aria-hidden="true"><circle cx="8" cy="8" r="5.5"/><path d="M8 5v3.2l2 1.3"/></svg>';
/// B: a clock before a shorter "After this turn".
const clockNote = alternate(`.cv-received__queued { display: inline-flex; align-items: center; gap: 4px; }`, (note) => {
  note.innerHTML = `${CLOCK}<span>After this turn</span>`;
});
/// C: a hairline pill that says "Queued", the rest in its tooltip.
const pillNote = alternate(
  `.cv-received__queued { padding: 0 6px; height: 16px; line-height: 16px; border-radius: 8px;
  box-shadow: inset 0 0 0 var(--cmux-hairline, 0.5px) color-mix(in srgb, var(--cv-text) 30%, transparent); }`,
  (note) => {
    note.title = note.textContent ?? "";
    note.textContent = "Queued";
  },
);

export default agentPaneEntry({
  id: "agent-pane.queued-agent-messages",
  title: "Queued messages from other agents",
  area: "Agent pane",
  height: 760,
  covers: [
    "agent-session/acpmux/conversation/QueuedMessageCard.tsx",
    "agent-session/acpmux/conversation/queuedMessages.ts",
    "agent-session/acpmux/ComposerQueue.tsx",
  ],
  variants: {
    eleven: {
      note: "Eleven agents' messages and one prompt of the person's wait for the running turn: each message is its received card after the turn with Read after this turn (A, shipped); the composer's queue is the person's one prompt, with no fold.",
      snapshot: elevenAndMine,
    },
    "eleven-minimal": {
      note: "The same in Minimal Mode: each waiting message is its one line, the note at its end.",
      display: MINIMAL,
      snapshot: elevenAndMine,
    },
    "note-clock": {
      note: "Gallery only (B): a clock and a shorter After this turn.",
      display: MINIMAL,
      snapshot: elevenAndMine,
      play: clockNote,
    },
    "note-pill": {
      note: "Gallery only (C): a hairline Queued pill, the rest in its tooltip.",
      display: MINIMAL,
      snapshot: elevenAndMine,
      play: pillNote,
    },
    menu: {
      note: "Play: a waiting message's ⋯ menu: Steer, Edit message, Turn off queueing, Delete.",
      snapshot: chat(running, { isWorking: true, queue: [queued[10]!, own] }),
      play: async (ctx) => {
        await ctx.hover({ selector: ".cv-received__line" });
        await ctx.waitFor(() => ctx.document.querySelector('[data-menu="queued-message"]'));
        ctx.document.querySelector<HTMLButtonElement>('[data-menu="queued-message"]')!.click();
        await ctx.waitFor(() => ctx.document.querySelectorAll('[role="menuitem"]').length >= 4);
      },
    },
    "steer-waiting": {
      note: "A message an agent steered into the running turn that the agent has not read yet: its received card with Read after this step; Send now is in its ⋯ menu. No spinner row.",
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
