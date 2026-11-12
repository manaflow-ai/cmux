// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// A prompt's age and a reply's age, side by side, in every shape messageAge writes: "just now",
// minutes, hours, "yesterday", days, then the date past a week (the year only when it is another
// year's). Leo, 2026-11-08: "the timestamps for the agent and then the timestamps for the user, they
// need to be congruent ... The agent in ours only has the exact timestamp. But the exact timestamp
// should be, like, shown on hover". Every row's hover row is shown here, so both ages read at once.
// The placement variants compare where the age sits against the buttons: `mirrored` is what ships
// (the buttons on the message's own edge, the age past them on the inner side, in both rows); the
// others restyle the same rows for comparison only.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../model";

const HOUR = 60;
const DAY = 24 * HOUR;

/// One prompt and its reply per age shape, the reply a minute after its prompt.
const ages = (from = 0): AcpmuxSnapshot => {
  const all: [string, string, number][] = [
    ["Sketch the uploader's retry", "Three tries, doubling from 200 ms.", 400 * DAY],
    ["Add jitter to the backoff", "Each wait now varies by up to 20 percent.", 10 * DAY],
    ["Log why it gave up", "It logs the last status and the try count.", 3 * DAY],
    ["Cover the give-up path", "Added a test that fakes three timeouts.", 26 * HOUR],
    ["Run the suite again", "All 48 pass.", 3 * HOUR],
    ["Rename the helper", "It is `retryUpload` now.", 4],
    ["Ship it", "Pushed to the branch.", 0],
  ];
  const pairs = all.slice(0, all.length - from);
  let seq = 0;
  const rows = pairs.flatMap(([prompt, reply, minutes]) => [
    user(prompt, minutes + 1, { seq: ++seq }),
    assistant(reply, minutes),
    summary(minutes, { seq: (seq += 2), status: "completed" }),
  ]);
  const snapshot = chat(rows);
  return { ...snapshot, summary: snapshot.summary && { ...snapshot.summary, family: "claude" } };
};

/// Shows every row's hover row at once, so the prompt's and the reply's ages sit in one frame.
const REVEAL = `
.cv-user__actions, .acpmux-turnSummary .cv-turn-actions, .cv-turn-actions .cv-turn-time, .cv-reply-actions {
  opacity: 1 !important;
  transition: none !important;
}`;

/// Comparison only: the age after the buttons in both rows.
const TRAILING = `.cv-user__actions .cv-message-footer-row > .cv-user__time { order: 99; }`;
/// Comparison only: the age before the buttons in both rows.
const LEADING = `.cv-turn-actions .cv-message-footer-row > .cv-turn-time, .cv-reply-actions > .cv-turn-time { order: -1; }`;

const restyle =
  (css: string) =>
  async (ctx: PlayContext): Promise<void> => {
    const style = ctx.document.createElement("style");
    style.dataset.galleryMessageTimes = "";
    style.textContent = css;
    ctx.document.head.append(style);
    await ctx.waitFor(
      () => ctx.document.querySelector("time.cv-turn-time") && ctx.document.querySelector("time.cv-user__time"),
    );
  };

export default agentPaneEntry({
  id: "agent-pane.message-times",
  title: "Message times",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/conversation/MessageActions.tsx#MessageTime",
    "agent-session/acpmux/conversation/MessageActions.tsx#ReplyTime",
    "agent-session/acpmux/conversation/relativeTime.ts#messageAge",
  ],
  anchors: [{ selector: ".acpmux-composer" }, { selector: ".acpmux-header" }],
  widths: { narrow: 400, normal: 760, wide: 760 },
  variants: {
    mirrored: {
      note: "Ships: in both rows the buttons hold the message's edge and the age sits past them on the inner side (a reply's after its buttons, a prompt's before them), in the same caption size and color; the age grows away from the buttons, so 'just now' turning into '1 minute ago' moves nothing.",
      snapshot: ages(),
      play: restyle(REVEAL),
    },
    "older-ages": {
      note: "Older rows in the shipped placement: 'yesterday', '3 days ago', then the date past a week ('Sep 26'), with its year in another year ('Aug 31, 2025').",
      snapshot: ages(3),
      play: restyle(REVEAL),
    },
    "both-trailing": {
      note: "Comparison: the age after the buttons in both rows. A prompt's buttons then shift left each time its age gains a word.",
      snapshot: ages(),
      play: restyle(REVEAL + TRAILING),
    },
    "both-leading": {
      note: "Comparison: the age before the buttons in both rows. A reply's buttons leave the prose's left edge and move each time the age changes.",
      snapshot: ages(),
      play: restyle(REVEAL + LEADING),
    },
    "on-hover": {
      note: "As a reader meets it: the rows at rest, the ages shown with their row on hover.",
      snapshot: ages(),
    },
    "answer-hover": {
      note: "Play: point at the latest reply; its row shows Copy, Pin, Read aloud and its age, 'just now', after the buttons.",
      snapshot: ages(),
      play: async (ctx) => ctx.hover({ text: "Pushed to the branch." }),
    },
  },
});
