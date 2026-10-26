// l10n-allow-file: gallery fixture text, not shipped UI.
// Composer height candidates for Leo and Lawrence's Goldilocks review. Every arm uses the same
// multi-paragraph draft at a normal and short pane height, so the cap is judged in both contexts.
import { agentPaneEntry } from "../../gallery/format";
import type { PlayContext } from "../../gallery/play";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";

const DRAFT = [
  "Find the smallest safe change for the composer height and explain the tradeoffs.",
  "",
  "Keep the transcript readable while this draft grows, preserve the inline attachments, and make the controls stay anchored below the field.",
  "",
  "Check chat, New Tab, and Cmd-I with the same long prompt. Record the old cap, the current cap, and the chosen cap in the review.",
  "",
  "Then add a focused regression test for a short pane and one for a normal pane before handing the branch to review.",
].join("\n");

const ALT_ID = "composer-height-candidate";
const FIELD = ".acpmux-composer-box .acpmux-md-field";
const rules: Record<string, string> = {
  "old-eight-lines": `${FIELD} { max-height: calc(var(--text-body--line-height, 22px) * 8 + var(--cmux-control-height, 23px)); }`,
  "current-forty-percent": `${FIELD} { max-height: max(calc(var(--text-body--line-height, 22px) * 8 + var(--cmux-control-height, 23px)), 40vh); }`,
  "thirty-percent": `${FIELD} { max-height: 30vh; }`,
};

const play = (candidate: string) => async (ctx: PlayContext) => {
  ctx.document.getElementById(ALT_ID)?.remove();
  const css = rules[candidate];
  if (css) {
    const style = ctx.document.createElement("style");
    style.id = ALT_ID;
    style.textContent = css;
    ctx.document.head.append(style);
  }
  await ctx.waitFor(() => {
    const field = ctx.document.querySelector<HTMLElement>(FIELD);
    return field !== null && field.scrollHeight > field.clientHeight + 1;
  });
};

const snapshot = chat([
  user("Make the composer comfortable for long design notes.", 3),
  assistant("I am comparing the height candidates now.", 2),
]);
const variant = (candidate: string, height: number, note: string) => ({
  height,
  note,
  ready: { draft: DRAFT },
  snapshot,
  play: play(candidate),
});

export default agentPaneEntry({
  id: "agent-pane.composer-height",
  title: "Composer height Goldilocks candidates",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 400, normal: 760, wide: 1100 },
  covers: ["agent-session/acpmux/MarkdownField.tsx", "agent-session/acpmux/markdownField.css"],
  keywords: ["composer", "height", "long draft", "goldilocks"],
  variants: {
    "old-eight-lines-normal": variant("old-eight-lines", 520, "Old baseline: eight body lines plus the control row, shown in a normal pane."),
    "old-eight-lines-short": variant("old-eight-lines", 300, "Old baseline: eight body lines plus the control row, shown in a short pane."),
    "current-forty-percent-normal": variant("current-forty-percent", 520, "Current #24984 policy: 40% wins over eight lines in a normal pane."),
    "current-forty-percent-short": variant("current-forty-percent", 300, "Current #24984 policy: the short pane still gives up height."),
    "thirty-percent-normal": variant("thirty-percent", 520, "Candidate: cap at 30% of a normal pane."),
    "thirty-percent-short": variant("thirty-percent", 300, "Candidate: cap at 30% of a short pane."),
    "chosen-twelve-lines-normal": variant("chosen", 520, "Chosen Goldilocks policy: twelve lines, bounded by 40%, in a normal pane."),
    "chosen-twelve-lines-short": variant("chosen", 300, "Chosen Goldilocks policy: twelve lines, bounded by 40%, in a short pane."),
  },
});
