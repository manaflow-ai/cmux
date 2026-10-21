// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// A prompt's bubble (UserBubble.tsx) and an answer's footer (TurnRows.tsx TurnFooter), with their
// hover rows as Claude Code desktop's: under the prompt its age, read receipt, Copy, Edit, Retry,
// Fork and Pin; under the answer Copy, Fork, Pin, Read aloud and its age. Edit shows on a Claude
// chat's prompts after its first turn, which acpmux can fork through (cx-ncc.60). The icon buttons
// name themselves in a tooltip on hover (the *-tooltip plays). A long prompt opens on its first ten
// lines, fading out, with Show more; a pasted block is a chip that opens in place (PromptText.tsx).
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
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
      note: "Hovering the latest prompt shows its row under the bubble's right edge; nothing else shows.",
      snapshot: turns(claude),
      play: async (ctx) => ctx.hover({ text: "Now cover it with a test that fakes two timeouts" }),
    },
    "answer-hover": {
      note: "Hovering an answer shows its row under its left edge: Copy, Fork, Pin, Read aloud, its age.",
      snapshot: turns(claude),
      play: async (ctx) => ctx.hover({ text: /uploader\.retry\.test\.ts/ }),
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
    "pasted-chip": {
      note: "A pasted 2,300-line stack trace is a chip under the typed question: its first words and line count.",
      snapshot: pastedPrompt(),
    },
    "pasted-chip-open": {
      note: "Play: the chip opens the whole paste in place, under it, with Show less to fold the prompt again.",
      snapshot: pastedPrompt(),
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-user__paste" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-user__paste[aria-expanded='true']"));
      },
    },
    "edit-tooltip": {
      note: "Play: hover the later prompt's pencil; the tooltip says Edit.",
      snapshot: turns(claude),
      play: hoverTooltip("Edit"),
    },
  },
});
