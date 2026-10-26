// l10n-allow-file: gallery fixture text, not shipped UI.
// The New Tab/Cmd-I composer uses the same height candidates as the chat composer.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { CWD, manySessions, noChat } from "../../../gallery/fixtures/acpmux";

const DRAFT = [
  "Find the smallest safe change for the composer height and explain the tradeoffs.",
  "",
  "Keep the transcript readable while this draft grows, preserve the inline attachments, and make the controls stay anchored below the field.",
  "",
  "Check chat, New Tab, and Cmd-I with the same long prompt. Record the old cap, the current cap, and the chosen cap in the review.",
  "",
  "Then add a focused regression test for a short pane and one for a normal pane before handing the branch to review.",
].join("\n");

const ALT_ID = "newtab-composer-height-candidate";
const FIELD = ".nt-field";
const rules: Record<string, string> = {
  "old-eight-lines": `${FIELD} { max-height: calc(8 * 1lh + 32px); }`,
  "current-forty-percent": `${FIELD} { max-height: min(calc(8 * 1lh + 32px), 40vh); }`,
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
    const field = ctx.document.querySelector<HTMLTextAreaElement>(FIELD);
    return field !== null && field.scrollHeight > field.clientHeight + 1;
  });
};
const ready = (height: number) => ({
  height,
  note: "Same long multi-paragraph draft as the chat candidates, in this New Tab/Cmd-I pane size.",
  ready: {
    newTab: { layout: "b", kind: "agent", cwd: CWD, home: "/Users/you", lastAgent: "claude", template: "composer" },
    newSession: true,
    draft: DRAFT,
  },
  snapshot: noChat(manySessions(3)),
});
const variant = (candidate: string, height: number, note: string) => ({ ...ready(height), note, play: play(candidate) });

export default agentPaneEntry({
  id: "agent-pane.newtab-composer-height",
  title: "New Tab composer height Goldilocks candidates",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 400, normal: 760, wide: 1100 },
  covers: ["agent-session/acpmux/newtab/NewTabScreen.tsx", "agent-session/acpmux/newtab/screen.css"],
  keywords: ["new tab", "Cmd-I", "composer", "height", "long draft"],
  variants: {
    "old-eight-lines-normal": variant("old-eight-lines", 520, "Old baseline: eight lines in a normal New Tab/Cmd-I pane."),
    "old-eight-lines-short": variant("old-eight-lines", 300, "Old baseline: eight lines in a short New Tab/Cmd-I pane."),
    "current-forty-percent-normal": variant("current-forty-percent", 520, "Current New Tab policy in a normal pane."),
    "current-forty-percent-short": variant("current-forty-percent", 300, "Current New Tab policy in a short pane."),
    "thirty-percent-normal": variant("thirty-percent", 520, "Candidate: 30% of a normal New Tab/Cmd-I pane."),
    "thirty-percent-short": variant("thirty-percent", 300, "Candidate: 30% of a short New Tab/Cmd-I pane."),
    "chosen-twelve-lines-normal": variant("chosen", 520, "Chosen Goldilocks policy: twelve lines bounded by 40%, normal pane."),
    "chosen-twelve-lines-short": variant("chosen", 300, "Chosen Goldilocks policy: twelve lines bounded by 40%, short pane."),
  },
});
