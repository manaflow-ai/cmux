// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// A prompt's bubble (UserBubble.tsx) and an answer's footer (TurnRows.tsx TurnFooter), with their
// hover rows: under the prompt its read receipt, its age, a dot, Copy, Retry and Fork (Leo's spec),
// then cmux's Edit; under the answer Claude's Copy, Fork, Pin, Read aloud and its age. Each age shows
// its exact date and time above it on hover (the *-time-tooltip plays). Edit shows on a Claude
// chat's prompts after its first turn, which acpmux can fork through (cx-ncc.60). The icon buttons
// name themselves in a tooltip on hover (the *-tooltip plays). A long prompt opens on its first ten
// lines, fading out, with Show more; a pasted block is a chip that opens in place (PromptText.tsx).
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { assistant, chat, session, summary, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../model";

const claude = (snapshot: AcpmuxSnapshot): AcpmuxSnapshot => ({
  ...snapshot,
  summary: snapshot.summary && { ...snapshot.summary, family: "claude" },
});

const turns = (family: (snapshot: AcpmuxSnapshot) => AcpmuxSnapshot) =>
  family(
    chat([
      user("Add retry with backoff to the uploader", 9, { seq: 1 }),
      assistant("Done: three tries, doubling from 200 ms, only on 5xx and timeouts.", 8.5),
      summary(8.5, { seq: 3, status: "completed" }),
      user("Now cover it with a test that fakes two timeouts", 6, { seq: 4 }),
      assistant("Added `uploader.retry.test.ts`; it passes and fails without the retry.", 5),
      summary(5, { seq: 6, status: "completed" }),
    ]),
  );

/// An edited sibling is still running while the original branch has finished (Leo, 2026-10-24):
/// the prompt keeps its version arrows, and the active branch's label carries the working spinner.
const runningEditBranches = (): AcpmuxSnapshot => {
  const base = claude(
    chat([
      user("Add retry with backoff to the uploader", 9, { id: "user-1", seq: 1 }),
      assistant("Done: three tries, doubling from 200 ms.", 8.5),
      summary(8.5, { id: "summary-1", seq: 4, status: "completed" }),
      user("Now cover it with two tests", 1, { id: "user-5", seq: 5 }),
      assistant("Running the edited test branch…", 0.5, { streaming: true }),
    ]),
  );
  return {
    ...base,
    sessionId: "fork-2",
    forkedAtSeq: 4,
    isWorking: true,
    sessions: [
      session({ sessionId: "parent", title: "Uploader retry", turnCount: 2 }),
      session({
        sessionId: "fork-1",
        title: "Uploader retry (first edit)",
        parentId: "parent",
        forkSeq: 4,
        turnCount: 2,
      }),
      session({
        sessionId: "fork-2",
        title: "Uploader retry (edited)",
        parentId: "parent",
        forkSeq: 4,
        turnCount: 2,
        lane: "working",
      }),
    ],
    summary: { ...base.summary!, sessionId: "fork-2", status: "running" },
  };
};

const LONG = Array.from(
  { length: 60 },
  (_, index) => `${index + 1}. The uploader retries ${index + 1} times before it gives up on a 5xx.`,
).join("\n");
const longPrompt = () =>
  claude(
    chat([
      user(LONG, 9, { seq: 1 }),
      assistant("Each retry doubles its wait from 200 ms; the counter never resets between uploads.", 8.5),
      summary(8.5, { seq: 3, status: "completed" }),
      user("Fix the counter", 6, { seq: 4 }),
      assistant("Done: the counter resets when an upload starts.", 5),
      summary(5, { seq: 6, status: "completed" }),
    ]),
  );
const TYPED = "Why does the upload fail after the second retry?";
const PASTE = Array.from({ length: 2300 }, (_, index) => `    at retry (uploader.ts:${index + 12}:7)`).join("\n");
const pastedPrompt = () => {
  const text = `${TYPED}\n${PASTE}`;
  return claude(
    chat([
      user(text, 9, { seq: 1, pasted: [{ start: TYPED.length + 1, end: text.length }] }),
      assistant("The stack shows the retry calling itself without awaiting the backoff.", 8.5),
      summary(8.5, { seq: 3, status: "completed" }),
    ]),
  );
};

/// One long paragraph pasted under a typed ask, as dictation or a chat message gives it: about
/// 1,100 words on a single line (Leo, 2026-11-05: "it says pasted text one line, but there's a lot
/// more than this").
const PARAGRAPH = Array.from(
  { length: 40 },
  (_, index) =>
    `Okay, but at the same time the retry helper in step ${index + 1} should back off a little longer each attempt, log why it gave up, and keep the`,
).join(" ");
const TIGHTEN = "Can you tighten this up?";
const pastedParagraph = () => {
  const text = `${TIGHTEN}\n${PARAGRAPH}`;
  return claude(
    chat([
      user(text, 9, { seq: 1, pasted: [{ start: TIGHTEN.length + 1, end: text.length }] }),
      assistant("Here it is in half the words.", 8.5),
      summary(8.5, { seq: 3, status: "completed" }),
    ]),
  );
};

/// A chat from 15 hours ago: its rows read "15 hours ago", their exact time above it on hover.
const yesterday = () =>
  claude(
    chat([
      user("Add retry with backoff to the uploader", 15 * 60 + 2, { seq: 1 }),
      assistant("Done: three tries, doubling from 200 ms, only on 5xx and timeouts.", 15 * 60),
      summary(15 * 60, { seq: 3, status: "completed" }),
    ]),
  );

/// Hovers the `selector` time and waits for its exact date and time to show above it.
const hoverTime = (selector: string) => async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(selector));
  await ctx.hover({ selector });
  await ctx.waitFor(() =>
    /\d{4}, \d/.test(ctx.document.querySelector(".ui-title-tooltip:not([hidden])")?.textContent ?? ""),
  );
};

/// Hovers the latest prompt's `label` button and waits for the pane's tooltip to name it.
const hoverTooltip = (label: string) => async (ctx: PlayContext) => {
  const selector = `.cv-user__actions button[aria-label="${label}"]`;
  await ctx.waitFor(() => ctx.document.querySelector(selector));
  await ctx.hover({ selector });
  await ctx.waitFor(
    () => ctx.document.querySelector(".ui-title-tooltip:not([hidden])")?.textContent?.startsWith(label) ?? false,
  );
};

export default agentPaneEntry({
  id: "agent-pane.user-bubble",
  title: "Prompt bubble",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/conversation/UserBubble.tsx",
    "agent-session/acpmux/conversation/PromptText.tsx",
    "agent-session/acpmux/conversation/MessageActions.tsx",
    "agent-session/acpmux/conversation/icons.tsx#DoubleCheck",
    "agent-session/acpmux/conversation/icons.tsx#Pin",
    "agent-session/acpmux/conversation/icons.tsx#Speaker",
  ],
  anchors: [{ selector: ".acpmux-composer" }, { selector: ".acpmux-header" }],
  variants: {
    claude: {
      note: "A Claude chat: hover a later prompt for Copy and Edit; the first prompt has Copy only.",
      snapshot: turns(claude),
    },
    "prompt-hover": {
      note: "Hovering the latest prompt shows its row under the bubble's right edge: age, Copy, Retry, Fork, Edit, without a check or state dot.",
      snapshot: turns(claude),
      play: async (ctx) => ctx.hover({ text: "Now cover it with a test that fakes two timeouts" }),
    },
    "running-edit-branches": {
      note: "An edited prompt runs in its sibling while the original branch finishes: the row shows 3/3 with previous/next arrows and a spinner on the running branch. Edit remains available during the run; switching back shows the finished branch without the spinner.",
      snapshot: runningEditBranches(),
      play: async (ctx) => {
        await ctx.hover({ text: "Now cover it with two tests" });
        const count = ctx.document.querySelector(".cv-user__version-count");
        if (count?.textContent?.trim() !== "3/3") throw new Error(`expected 3/3, got ${count?.textContent}`);
        if (!count.querySelector("svg")) throw new Error("the running branch has no spinner");
        if (!ctx.document.querySelector('.cv-user__versions button[aria-label="Previous version"]'))
          throw new Error("the running branch has no previous-version arrow");
      },
    },
    "finished-original-branch": {
      note: "The original branch after the edited sibling finishes: the same prompt keeps its 1/3 version arrows, with no running spinner.",
      snapshot: (() => {
        const snapshot = runningEditBranches();
        return {
          ...snapshot,
          sessionId: "parent",
          isWorking: false,
          rows: snapshot.rows.map((row) => (row.kind === "assistant" ? { ...row, streaming: false } : row)),
          summary: { ...snapshot.summary!, sessionId: "parent", status: "completed" },
        };
      })(),
    },
    "answer-hover": {
      note: "Hovering an answer shows its row under its left edge: Copy, Fork, Pin, Read aloud, its age.",
      snapshot: turns(claude),
      play: async (ctx) => ctx.hover({ text: /uploader\.retry\.test\.ts/ }),
    },
    "prompt-time-tooltip": {
      note: "Play: hover a prompt's age (15 hours ago); its exact date and time show above it (month, day, year, then the time).",
      snapshot: yesterday(),
      play: hoverTime("time.cv-user__time"),
    },
    "answer-time-tooltip": {
      note: "Play: point at an answer's footer; its exact date and time shows at the row's end, after the buttons (hidden at rest, as ChatGPT's: #31609), its tooltip the turn's time and tokens.",
      snapshot: yesterday(),
      play: async (ctx) => {
        const selector = "time.cv-turn-time";
        await ctx.waitFor(() => ctx.document.querySelector(selector));
        await ctx.hover({ selector });
        await ctx.waitFor(() => {
          const time = ctx.document.querySelector<HTMLElement>(selector);
          return (
            time !== null &&
            /\d:\d\d/.test(time.textContent ?? "") &&
            ctx.document.defaultView!.getComputedStyle(time).opacity === "1"
          );
        });
      },
    },
    other: {
      note: "Another agent forks only at a chat's end: prompts offer Copy only.",
      snapshot: turns((snapshot) => snapshot),
    },
    "copy-tooltip": {
      note: "Play: hover the prompt's Copy; the tooltip names it (a click turns it into a check for a moment).",
      snapshot: claude(
        chat([
          user("Add retry with backoff to the uploader", 9, { seq: 1 }),
          assistant("Done: three tries, doubling from 200 ms, only on 5xx and timeouts.", 8.5),
          summary(8.5, { seq: 3, status: "completed" }),
        ]),
      ),
      play: hoverTooltip("Copy"),
    },
    "long-collapsed": {
      note: "A 60-line prompt opens on its first ten lines, the last ones fading out, with Show more under them.",
      snapshot: longPrompt(),
    },
    "long-expanded": {
      note: "Play: Show more opens the whole prompt in place; Show less closes it again.",
      snapshot: longPrompt(),
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-user__more" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-user__more[aria-expanded='true']"));
      },
    },
    short: {
      note: "A short prompt is unchanged: its whole text, no fade, no Show more.",
      snapshot: turns(claude),
    },
    "markdown-quote": {
      note: "A sent prompt reuses transcript Markdown: quoted lines draw with a muted left bar and quiet ink instead of raw greater-than markers.",
      snapshot: claude(
        chat([
          user("> The upload retries forever\n> when the network is offline.\n\nAdd a bounded backoff.", 9, { seq: 1 }),
          assistant("Added a five-attempt cap and a reset on the next upload.", 8.5),
          summary(8.5, { seq: 3, status: "completed" }),
        ]),
      ),
    },
    "markdown-parity": {
      note: "Sent prompts render quotes, lists, inline code, fenced code and links with the transcript renderer. The second prompt has no quote marker.",
      snapshot: claude(
        chat([
          user(
            "> The uploader retries forever.\n> It should stop after three attempts.\n\nKeep that limit visible.",
            9,
            {
              id: "markdown-quote",
              seq: 1,
            },
          ),
          assistant("The quote remains distinct from your reply.", 8.5),
          summary(8.5, { seq: 3, status: "completed" }),
          user(
            "1. Keep `retry_count` bounded.\n2. Report **exhausted** attempts.\n\n```text\nretry_count = 3\n```\n\n[Read the retry guide](https://example.com/retry)",
            6,
            { id: "markdown-list", seq: 4 },
          ),
          assistant("The list, code and link remain formatted after sending.", 5),
          summary(5, { seq: 6, status: "completed" }),
        ]),
      ),
    },
    "markdown-long-tokens": {
      note: "A delivered review with inline code, paths and a 40-character SHA range: the code draws as code, and the range ends a line after its `..` or a path after a `/`, never mid-hash.",
      snapshot: claude(
        chat([
          user(
            "Review of manaflow-ai/cmux:4f1c2a9be07d3e6f58a1b2c3d4e5f60718293a4b..8e0c5dda55f4d5d0821cf21a4b520c2397145d00 by review-box/review-27240-2c1e: SHIP\n\n`repeatsPrompt` now stays false for a queued prompt; `webviews/src/agent-session/acpmux/conversation/PromptText.tsx` and `webviews/test/user-prompt-markdown.test.ts` cover it.",
            9,
            { id: "markdown-long-tokens", seq: 1 },
          ),
          assistant("Landing it at that head.", 8.5),
          summary(8.5, { seq: 3, status: "completed" }),
        ]),
      ),
    },
    "pasted-chip": {
      note: "A pasted 2,300-line stack trace is a card under the typed question: its first three lines, the last fading, over 'Pasted text', its line count and its characters.",
      snapshot: pastedPrompt(),
    },
    "pasted-chip-open": {
      note: "Play: the card opens in place, the same text growing to the whole paste, its label under it to close it, with Show less to fold the prompt again.",
      snapshot: pastedPrompt(),
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-user__paste" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-user__paste[aria-expanded='true']"));
      },
    },
    "pasted-paragraph": {
      note: "One pasted paragraph of 1,100 words: its first three lines wrapped at the bubble's width, and its size in characters, never '1 line'.",
      snapshot: pastedParagraph(),
    },
    "pasted-paragraph-open": {
      note: "Play: the paragraph's card opens in place to the whole paragraph.",
      snapshot: pastedParagraph(),
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-user__paste" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-user__paste[aria-expanded='true']"));
      },
    },
    editing: {
      note: "Play: Edit opens the prompt in place on the bubble's own glass, 12 radius and 16 sides, at the bubble's widest, so its right edge stays put; Cancel and Send under the text.",
      snapshot: turns(claude),
      play: async (ctx) => {
        await ctx.hover({ text: "Now cover it with a test that fakes two timeouts" });
        await ctx.click({ selector: '.cv-user__actions button[aria-label="Edit"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-user__edit"));
      },
    },
    "edit-tooltip": {
      note: "Play: hover the later prompt's pencil; the tooltip says Edit.",
      snapshot: turns(claude),
      play: hoverTooltip("Edit"),
    },
  },
});
