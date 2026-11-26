// l10n-allow-file: gallery fixture text, not shipped UI.
// Leo, 2026-11-23 (ask-525a5e502a), paraphrased: adding attachments must not make the composer even
// taller; have them within the top part of the composer, the inner area grows at the top, no shift,
// nothing. The strip (Attachments at Top) sits inside the top of the card and takes its height out
// of the prompt's max height (composerAttachments.css --acpmux-attach-band, markdownField.css), so a
// draft at the cap keeps the card's height and top edge when attachments land. One scene per arm of
// `composer-attach-strip-size` (composer/attachStrip.experiment.ts), at the cap and on a short
// draft, and the capped card with nothing attached to compare against.
// test/composer-attachments-inside-cap.test.ts measures it.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import type { PlayContext } from "../../gallery/play";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";
import { COMPOSER_MD_FIELD } from "./composerSelectors";

const LONG = Array.from({ length: 40 }, (_, line) => `Line ${line + 1} of a long design note for the composer.`).join(
  "\n",
);

const snapshot = ((base) => ({ ...base, summary: { ...base.summary!, promptCapabilities: { image: true } } }))(
  chat([
    user("Make attachments fit inside the composer.", 3),
    assistant("The strip now shares the prompt's max height.", 2),
  ]),
);

/// `count` screenshots pasted into the strip view; waits for every tile to draw.
const attach = (count: number) => async (ctx: PlayContext) => {
  const view = ctx.document.defaultView!;
  view.cmuxAcpmuxComposer?.({ attachmentView: "strip" });
  await ctx.waitFor(
    () => ctx.document.querySelector(".acpmux-composer-box")?.getAttribute("data-attachment-view") === "strip",
  );
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
  if (count > 0) {
    const data = new view.DataTransfer();
    for (const file of files) data.items.add(file);
    const paste = new view.Event("paste", { bubbles: true, cancelable: true });
    Object.defineProperty(paste, "clipboardData", { value: data });
    ctx.find({ selector: ".acpmux-md" }).dispatchEvent(paste);
    await ctx.waitFor(
      () => ctx.document.querySelectorAll(".acpmux-attachments .acpmux-attachment img").length === count,
    );
  }
  await ctx.waitFor(() => {
    const field = ctx.document.querySelector<HTMLElement>(COMPOSER_MD_FIELD);
    return field !== null && field.getBoundingClientRect().height > 0;
  });
};

const ARMS = {
  tiles: "64 px thumbnails (the default)",
  compact: "44 px compact thumbnails",
  chips: "a 32 px chips row",
} as const;

const variants: Record<string, AgentPaneVariant> = {
  "cap-nothing-attached": {
    note: "A draft past the prompt's max height with nothing attached: the card's height every at-cap scene keeps.",
    ready: { draft: LONG },
    snapshot,
    play: attach(0),
  },
};
for (const [arm, label] of Object.entries(ARMS)) {
  variants[`${arm}-at-cap`] = {
    note: `${label}: three screenshots on a capped draft. The strip takes its row out of the prompt's max height, so the card keeps its height and top edge.`,
    experiments: { "composer-attach-strip-size": arm },
    ready: { draft: LONG },
    snapshot,
    play: attach(3),
  };
  variants[`${arm}-one-line`] = {
    note: `${label}: two screenshots on a one-line draft. The card grows at its top by one strip row; the bottom edge stays put.`,
    experiments: { "composer-attach-strip-size": arm },
    ready: { draft: "Which of these layouts reads better?" },
    snapshot,
    play: attach(2),
  };
}

export default agentPaneEntry({
  id: "agent-pane.composer-attachments-cap",
  title: "Composer attachments inside the cap",
  area: "Agent pane",
  height: 620,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  anchors: [{ selector: ".acpmux-attachments" }, { selector: ".acpmux-composer-box" }],
  covers: ["agent-session/acpmux/composerAttachments.css", "agent-session/acpmux/markdownField.css"],
  keywords: ["composer", "attachments", "strip", "cap", "max height"],
  variants,
});
