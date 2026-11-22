// l10n-allow-file: gallery fixtures (sample transcript times), not shipped UI.
// A clock time anywhere in an agent's prose hovers, not only right after "at" (ask-15a0d92575;
// Leo, 2026-11-07, on "...n at 03:22 t..." with no hover: "we should probably be able to just
// detect this as like, oh yeah, this is a timestamp"). A bare time is the reader's zone, the
// occurrence nearest the message; a date or an offset keeps its own. The gallery's now is 09:41Z
// and the capture page reads UTC. Compare arms shows the `time-hover-date` experiment.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import { timeHoverDate } from "./timeHoverDate.experiment";

const ask = "Where is the deploy?";

/** Hovers the message's first marked time and waits for its tooltip to be fully shown. */
const hoverTime: Play = async (ctx) => {
  await ctx.hover({ deep: "time.cv-time-hover" });
  await ctx.waitFor(() => {
    const popup = ctx.document.querySelector<HTMLElement>('[role="tooltip"]');
    return popup && ctx.document.defaultView?.getComputedStyle(popup).opacity === "1";
  });
};

const prose = [
  "The deploy finished 09:22, and the rerun starts 09:56 once the cache warms.",
  "Shard 3 retried between 09:30-09:34; the window closes 11:00.",
].join("\n\n");

const dated = [
  "The incident opened 2026-10-05 22:10 and the fix shipped Oct 6, 2026 at 8:05 AM.",
  "The vendor's cutover is 12:30+02:00 (their time), and the backup runs 06:00 -0700.",
].join("\n\n");

// None of these are times: each stays plain text.
const lookAlikes = [
  "A 16:10 display at aspect ratio 16:9; the team won 21:15 and the score was 3:1.",
  "The error is at `src/app.ts:12:30`, see also foo.ts:12:30 and line 12:30.",
  "The job took 01:23:45, with 12:30 left; Psalm 23:10 and John 3:16; v1.12:30 on localhost:8080 and fe80::12:30.",
].join("\n\n");

export default agentPaneEntry({
  id: "agent-pane.time-hover-detect",
  title: "Clock times found in prose",
  area: "Agent pane",
  height: 300,
  covers: [
    "agent-session/acpmux/conversation/timeHover.tsx",
    "agent-session/acpmux/conversation/timeHoverDate.experiment.ts",
  ],
  variants: {
    "bare-time": {
      note: 'Leo\'s case: a bare 24-hour time with no "at" before it, 15 minutes ahead. The hover gives the local date and time and "in 15 min".',
      snapshot: chat([user(ask, 1), assistant("The rerun starts 09:56 once the cache warms.", 0)]),
      play: hoverTime,
    },
    prose: {
      note: "Every bare 24-hour time in the reply is dotted-underlined, including both ends of a range.",
      snapshot: chat([user(ask, 1), assistant(prose, 0)]),
    },
    dated: {
      note: "A date and time, or a time with an offset, keeps its own day and zone.",
      snapshot: chat([user("When did it start?", 1), assistant(dated, 0)]),
    },
    "no-leading-zero": {
      note: '"at 9:56" (no leading zero, no AM/PM) is detected only after at/by/around/until/till, and reads as whichever half of the day is nearer.',
      snapshot: chat([user(ask, 1), assistant("Let's check again at 9:56, then by 10:30.", 0)]),
      play: hoverTime,
    },
    "look-alikes": {
      note: "Ratios, scores, line:col, durations, verses, versions, ports and addresses stay plain: no underline, no hover.",
      height: 340,
      snapshot: chat([user("Anything else?", 1), assistant(lookAlikes, 0)]),
    },
  },
  experiment: {
    definition: timeHoverDate,
    script: [{ name: "hover the bare time", run: hoverTime }],
  },
});
