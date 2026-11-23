// l10n-allow-file: gallery fixtures (sample transcript timestamps), not shipped UI.
// Times in an agent's message are dotted-underlined, with the local time and an age on hover. A
// time with no date is the one nearest the message's own send time (Leo, 2026-11-07, on "08:36Z"
// in a message sent at 08:21Z hovering as "24 hr ago": "It's too biased towards the past here.").
// The gallery's now is 09:41Z. Compare arms shows the `time-hover-wording` experiment on a time
// the message pointed ahead to that has since passed.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import { timeHoverWording } from "./timeHoverWording.experiment";

const reply = [
  "The first worker finished since about 04:50Z, and the follow-up landed at 04:38:12Z.",
  "The release event was 2026-10-24T05:21:28Z (local time is shown on hover), with the handoff at 05:22 UTC.",
  "Inline code stays literal: `05:23Z`. A fenced example stays literal too:",
  "```text\n2026-10-24T05:24:00Z\n```",
].join("\n\n");

const ask = "When does the rerun finish?";

/** Hovers the message's one marked time and waits for its tooltip to be fully shown. */
const hoverTime: Play = async (ctx) => {
  await ctx.hover({ deep: "time.cv-time-hover" });
  await ctx.waitFor(() => {
    const popup = ctx.document.querySelector<HTMLElement>('[role="tooltip"]');
    return popup && ctx.document.defaultView?.getComputedStyle(popup).opacity === "1";
  });
};

export default agentPaneEntry({
  id: "agent-pane.time-hover",
  title: "Hoverable transcript times",
  area: "Agent pane",
  height: 420,
  covers: [
    "agent-session/acpmux/conversation/Markdown.tsx",
    "agent-session/acpmux/conversation/timeHover.tsx",
    "agent-session/acpmux/conversation/timeHoverWording.experiment.ts",
  ],
  variants: {
    transcript: {
      note: "Assistant Markdown timestamps become keyboard-focusable local-time tooltips; hover or focus the dotted-underlined times. The same state is readable in the gallery's light and dark themes.",
      snapshot: chat([user("Summarize the worker handoff and call out the exact times.", 4), assistant(reply, 2)]),
    },
    ahead: {
      note: 'Leo\'s case: 09:56Z written at 09:41Z is 15 minutes ahead, today. The hover says "in 15 min" (before: "24 hr ago").',
      height: 260,
      snapshot: chat([user(ask, 1), assistant("At about 09:56Z, after the rerun finishes, I'll post the numbers.", 0)]),
      play: hoverTime,
    },
    passed: {
      note: "The same message read three hours later: the time the message pointed ahead to says how long after the message it was.",
      height: 260,
      snapshot: chat([
        user(ask, 181),
        assistant("At about 06:56Z, after the rerun finishes, I'll post the numbers.", 180),
      ]),
      play: hoverTime,
    },
    before: {
      note: "A time before its message still reads as an age: 09:25Z written at 09:41Z.",
      height: 260,
      snapshot: chat([user("When did it fail?", 1), assistant("It failed at 09:25Z, on the second shard.", 0)]),
      play: hoverTime,
    },
    "twelve-hour": {
      note: "A 12-hour time with UTC follows the same rule: 9:56 AM UTC, 15 minutes ahead.",
      height: 260,
      snapshot: chat([user(ask, 1), assistant("By 9:56 AM UTC the rerun is done.", 0)]),
      play: hoverTime,
    },
  },
  experiment: {
    definition: timeHoverWording,
    script: [{ name: "hover the passed time", run: hoverTime }],
  },
});
