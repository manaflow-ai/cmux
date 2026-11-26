// l10n-allow-file: gallery fixtures (a sample chat and drafts), not shipped UI.
// The composer as its draft grows (Leo 2026-11-23: "buttons need to be at the bottom ... why ... if
// your composer grows in length, should the buttons you ... reach for stray away from you?"): +, the
// mic and Send sit on the draft's last line at 1, 3 and 8 lines and at the cap with the draft
// scrolled inside, and the tucked hat's "^ 3" pill rides the composer's top edge up with it. The
// thumb is inside the box and shows only for a moment after the length changes or the draft scrolls
// (design/composer-bottom-controls.md); these stills are at rest, so no thumb is drawn. Each draft
// line is short enough to stay one line at the narrow width, so the line count is the variant's.
// test/composer-bottom-controls.browser.test.ts measures these variants.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { assistant, chat, row, user } from "../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../gallery/clock";
import { SUBAGENTS, type Subagent } from "./subagents/subagentFold";
import { COMPOSER_MD_FIELD } from "./composerSelectors";

const running = (name: string): Subagent => ({
  id: `agent-${name.toLowerCase().replaceAll(" ", "-")}`,
  parent: null,
  name,
  task: name,
  state: "running",
  startedAt: minutesAgo(5),
});

const snapshot = chat(
  [
    user("Review the retry change from three sides", 6),
    row(SUBAGENTS, 5.5, {
      subagents: [running("Review the retry loop"), running("Review the tests"), running("Review the docs")],
    }),
    assistant("Three reviewers are reading the change now.", 4),
  ],
  { isWorking: true },
);

/** A draft of `lines` short lines (each one line at the narrow width). */
export const growthDraft = (lines: number): string =>
  Array.from({ length: lines }, (_, index) => `Line ${index + 1}: keep retries in sync.`).join("\n");

/** Line counts per variant; `max` is past the cap, its draft scrolled to the end inside the box. */
export const GROWTH_LINES = { "lines-1": 1, "lines-3": 3, "lines-8": 8, "max-scroll": 40 } as const;

const settle =
  (lines: number): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-tray-pull__tab"));
    await ctx.waitFor(() => {
      const field = ctx.document.querySelector<HTMLElement>(COMPOSER_MD_FIELD);
      if (!field) return false;
      const text = field.textContent ?? "";
      return text.includes(`Line ${lines}:`);
    });
    if (lines >= GROWTH_LINES["max-scroll"]) {
      const field = ctx.document.querySelector<HTMLElement>(COMPOSER_MD_FIELD)!;
      await ctx.waitFor(() => field.scrollHeight > field.clientHeight + 1);
      field.scrollTop = field.scrollHeight;
    }
  };

const variant = (lines: number, note: string) => ({
  composerLook: "claude" as const,
  note,
  snapshot,
  display: { "agentPane.display.trayTucked": true },
  ready: { draft: growthDraft(lines) },
  play: settle(lines),
});

export default agentPaneEntry({
  id: "agent-pane.composer-bottom-controls",
  title: "Composer controls on the last line as the draft grows",
  area: "Agent pane",
  height: 720,
  widths: { narrow: 400, wide: 1100 },
  covers: [
    "agent-session/acpmux/composerLocation.css",
    "agent-session/acpmux/composerScrollLane.ts",
    "agent-session/acpmux/markdownField.css",
  ],
  keywords: ["composer", "grow", "bottom", "send", "mic", "plus", "scrollbar", "thumb", "pull tab"],
  variants: {
    "lines-1": variant(1, "One line: +, the mic and Send on the draft's line."),
    "lines-3": variant(3, "Three lines: the controls on the third line, the pill on the top edge above it."),
    "lines-8": variant(8, "Eight lines: the controls on the eighth line."),
    "max-scroll": variant(
      40,
      "Past the cap, scrolled to the end inside the box: the controls on the last visible line.",
    ),
  },
});
