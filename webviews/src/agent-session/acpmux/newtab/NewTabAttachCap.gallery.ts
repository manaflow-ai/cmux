// l10n-allow-file: gallery fixture text, not shipped UI.
// Leo, 2026-11-23 (ask-525a5e502a), paraphrased: adding attachments must not make the composer even
// taller; this goes for the GUI chat too; have them within the top part of the composer, the inner
// area grows at the top, no shift, nothing. The New Tab page's strip sits inside the top of its box
// and the field gives up the strip's band from its max height (screen.css for NewTabScreen,
// styles.css and composerAttachments.css for Classic NewTabPage), so a capped draft keeps the box's
// height when attachments land. The chat pane's scenes: agent-pane.composer-attachments-cap.
// test/new-tab-attachments-inside-cap.test.ts measures it.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { CWD, manySessions, noChat } from "../../../gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../MarkdownField";

const LONG = Array.from(
  { length: 40 },
  (_, line) => `Line ${line + 1} of a long design note for the New Tab composer.`,
).join("\n");
const SHORT = "Which of these layouts reads better?";

const newTab = (template: "minimal" | "classic") => ({
  newTab: { layout: "b", kind: "agent", cwd: CWD, home: "/Users/you", lastAgent: "claude", template, projects: [CWD] },
  newSession: true,
});

const FIELD = { minimal: ".nt-field", classic: ".acpmux-newtab-field" } as const;

/// Settings' strip view, the draft, then `count` screenshots pasted on the field; waits for every tile.
const play = (template: keyof typeof FIELD, draft: string, count: number) => async (ctx: PlayContext) => {
  const view = ctx.document.defaultView!;
  view.cmuxAcpmuxComposer?.({ attachmentView: "strip" });
  await ctx.waitFor(() =>
    Boolean(ctx.document.querySelector<MarkdownFieldElement>(FIELD[template])?.acpmuxMarkdownField),
  );
  ctx.document.querySelector<MarkdownFieldElement>(FIELD[template])!.acpmuxMarkdownField!.type(draft);
  if (count === 0) return;
  const files = await Promise.all(
    Array.from({ length: count }, async (_, index) => {
      const canvas = new view.OffscreenCanvas(640, 400);
      const paint = canvas.getContext("2d")!;
      paint.fillStyle = `hsl(${210 + index * 40} 45% 45%)`;
      paint.fillRect(0, 0, 640, 400);
      paint.fillStyle = "#ffffffcc";
      for (let line = 0; line < 6; line += 1) paint.fillRect(40, 50 + line * 52, 520 - line * 50, 22);
      return new view.File([await canvas.convertToBlob({ type: "image/png" })], `shot-${index + 1}.png`, {
        type: "image/png",
      });
    }),
  );
  const data = new view.DataTransfer();
  for (const file of files) data.items.add(file);
  const paste = new view.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(paste, "clipboardData", { value: data });
  ctx.find({ selector: `${FIELD[template]} [contenteditable=true]` }).dispatchEvent(paste);
  await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-attachments .acpmux-attachment img").length === count);
  // The suggestions close, so the capture shows the box alone.
  await ctx.press("Escape");
};

const variants: Record<string, AgentPaneVariant> = {};
for (const [template, label] of [
  ["minimal", "New Tab"],
  ["classic", "Classic New Tab"],
] as const) {
  variants[`${template}-cap-nothing-attached`] = {
    note: `${label}: a draft past the field's max height with nothing attached, the box's height the at-cap scene keeps.`,
    ready: newTab(template),
    snapshot: noChat(manySessions(3)),
    play: play(template, LONG, 0),
  };
  variants[`${template}-at-cap`] = {
    note: `${label}: three screenshots on a capped draft. The strip heads the box and takes its row out of the field's max height, so the box keeps its height and edges.`,
    ready: newTab(template),
    snapshot: noChat(manySessions(3)),
    play: play(template, LONG, 3),
  };
  variants[`${template}-one-line`] = {
    note: `${label}: two screenshots on a one-line draft, inside the top of the box over the text.`,
    ready: newTab(template),
    snapshot: noChat(manySessions(3)),
    play: play(template, SHORT, 2),
  };
}

export default agentPaneEntry({
  id: "agent-pane.new-tab-attachments-cap",
  title: "New Tab attachments inside the cap",
  area: "New Tab",
  height: 720,
  widths: { narrow: 480, normal: 860, wide: 1200 },
  anchors: [{ selector: ".acpmux-attachments" }],
  covers: [
    "agent-session/acpmux/newtab/screen.css",
    "agent-session/acpmux/newtab/NewTabScreen.tsx",
    "agent-session/acpmux/NewTabPage.tsx",
    "agent-session/acpmux/composerAttachments.css",
  ],
  keywords: ["new tab", "attachments", "strip", "cap", "max height"],
  variants,
});
