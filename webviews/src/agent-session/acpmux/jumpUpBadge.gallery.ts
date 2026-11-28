// l10n-allow-file: sample transcript and comparison notes, not shipped UI.
// The one jump control pointing up to rows the reader has not seen (jumpControl.ts, VirtualTranscript.tsx
// `JumpToLatest` `up`, jumpPair.css), in each arm of its mark (jumpPair.experiment.ts `jump-up-badge`):
// the accent dot (#41506, ships), the count badge (#40813) and the plain arrow. Leo, 2026-11-12: "it
// doesn't actually keep track of, like, when the things". Each variant opens at the latest message with
// the reader's cursor ten turns back, so the first unseen reply is far above the view. Light and dark:
// ?colorScheme=light / dark.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "./model";
import { jumpUpBadge, type JumpUpBadge } from "./jumpPair.experiment";
import { jumpUpButton } from "./jumpUp.experiment";

const turns = (from: number, count: number, ago: number) =>
  Array.from({ length: count }, (_, index) => [
    user(`Check retry case ${from + index}`, ago - index * 2),
    assistant(
      `Case ${from + index} passes. The client retries a temporary transport failure, keeps the original request id, and stops after the last attempt. `.repeat(
        3,
      ),
      ago - index * 2 - 1,
    ),
    summary(ago - index * 2 - 1, { status: "completed" }),
  ]).flat();

/// Each row with the seq of the record that began it, as the pane's rows carry.
const numbered = (rows: AcpmuxRow[]): AcpmuxRow[] =>
  rows.map((each, index) => ({ ...each, seq: each.seq ?? index + 1 }));

// Eight turns the person saw (24 rows: their cursor), then seven they did not.
const snapshot = chat(numbered([...turns(1, 8, 120), ...turns(9, 7, 60)]), { readThrough: 24 });

const upShown: Play = async (ctx) => {
  await ctx.waitFor(() => (ctx.document.querySelector<HTMLElement>(".acpmux-scroll")?.scrollHeight ?? 0) > 1_500);
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-jump-latest[data-jump="up"][data-shown]'));
};

// The control turns up only with Jump up on (jumpUp.experiment.ts, off by default).
const badge = (arm: JumpUpBadge) => ({ experiments: { [jumpUpBadge.id]: arm, [jumpUpButton.id]: "on" } });

export default agentPaneEntry({
  id: "agent-pane.jump-up-badge",
  title: "Jump up to unseen rows: the mark",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 420, normal: 900, wide: 1600 },
  covers: [
    "agent-session/acpmux/jumpControl.ts",
    "agent-session/acpmux/VirtualTranscript.tsx#JumpToLatest",
    "agent-session/acpmux/jumpPair.css",
  ],
  keywords: ["jump up", "unseen", "unread", "seen cursor", "badge", "dot"],
  experiment: { definition: jumpUpBadge, script: [{ name: "Open with unseen turns above", run: upShown }] },
  variants: {
    dot: {
      note: "Selected (ships): the theme's accent dot at the disc's top end, the sidebar's unread dot; the arrow points up.",
      snapshot,
      play: upShown,
      ...badge("dot"),
    },
    count: {
      note: "Compared: an accent badge with the unseen turns (7), as chat apps count unread messages.",
      snapshot,
      play: upShown,
      ...badge("count"),
    },
    plain: {
      note: "Compared: only the arrow turned up; says less than the dot that something is new.",
      snapshot,
      play: upShown,
      ...badge("plain"),
    },
  },
});
