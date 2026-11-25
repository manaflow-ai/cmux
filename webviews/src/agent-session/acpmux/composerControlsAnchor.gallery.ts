// l10n-allow-file: gallery fixtures (sample prompts and file names), not shipped UI.
// Where Claude's look puts +, the mic and Send as the prompt grows. Leo, 2026-11-18, typed in his
// NIGHTLY's composer over a screen recording and a pasted-text card, with + and the mic level with
// the attachments' top: "the buttons should be at the bottom of the composer". Claude and Codex
// keep them on the box's bottom edge. The box with nothing in it, one attachment, three
// (a screenshot, a screen recording and a pasted log, Leo's prompt) and a four-line draft; compare
// arms (`composer-controls-anchor`) for the last line (ships), their own row, and the first line
// (before).
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";
import { SCREEN_RECORDING_POSTER_JPEG } from "../../gallery/fixtures/videoPoster";
import type { PlayContext } from "../../gallery/play";
import { composerControlsAnchor } from "./composerControlsAnchor.experiment";

const VIDEO_PATH = "/Users/dev/Desktop/Screen Recording 2026-11-18 at 2.51.03 PM.mov";
const SCREENSHOT_PATH = "/Users/dev/Desktop/Screenshot.png";
const VIDEO_INFO = {
  durationMs: 7_300,
  width: 1380,
  height: 548,
  poster: `data:image/jpeg;base64,${SCREEN_RECORDING_POSTER_JPEG}`,
  frames: [],
};
const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

const finished = [
  user("Why does the hover card move?", 10),
  assistant("It grows out of its tab on its first show.", 9),
  summary(9, { status: "completed" }),
];

/** Drops `kinds` on the prompt, in the inline view, as Finder does; waits for each tile. */
async function drop(ctx: PlayContext, kinds: ("video" | "screenshot")[]) {
  const view = ctx.document.defaultView!;
  view.cmuxAcpmuxComposer?.({ attachmentView: "inline" });
  const png = Uint8Array.from(atob(PNG), (char) => char.charCodeAt(0));
  const files = kinds.map((kind) =>
    kind === "screenshot"
      ? new view.File([png], "Screenshot.png", { type: "image/png" })
      : new view.File([new Uint8Array([0, 0, 0, 0x14, 0x66, 0x74, 0x79, 0x70])], VIDEO_PATH.split("/").pop()!, {
          type: "video/quicktime",
        }),
  );
  const event = new view.Event("drop", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "dataTransfer", { value: { files, types: ["Files"] } });
  ctx.find({ selector: ".acpmux-md" }).dispatchEvent(event);
  await ctx.waitFor(() => ctx.document.querySelectorAll("[data-inline-attachment] img").length === kinds.length);
}

/** Pastes a 600-line log: a Pasted text card in the prompt. */
async function pasteLog(ctx: PlayContext) {
  const view = ctx.document.defaultView!;
  const data = new view.DataTransfer();
  const log = Array.from({ length: 600 }, (_, index) => `cd ~/Projects && timeout 30 step ${index + 1}`);
  data.setData("text/plain", log.join("\n"));
  const event = new view.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: data });
  ctx.find({ selector: ".acpmux-md" }).dispatchEvent(event);
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-md-inline-chip[data-preview="text"]'));
}

/** The controls' bottoms, each to the box's bottom: equal, and (but in the first-line arm, the
 * layout before) on the box's bottom edge, not up by the first line. */
function checkBottom(ctx: PlayContext) {
  const boxElement = ctx.find({ selector: ".acpmux-composer-box" });
  const box = boxElement.getBoundingClientRect();
  const plus = ctx.find({ selector: ".acpmux-composer-inner > .acpmux-composer-plus" }).getBoundingClientRect();
  const actions = ctx.find({ selector: ".acpmux-composer-inner > .acpmux-composer-actions" }).getBoundingClientRect();
  const under = [box.bottom - plus.bottom, box.bottom - actions.bottom];
  if (Math.abs(under[0]! - under[1]!) > 0.5)
    throw new Error(`+ stands ${under[0]} px over the box's bottom, Send ${under[1]}`);
  if (box.height < 60) throw new Error(`the prompt did not grow (${box.height} px)`);
  const arm = boxElement.closest("[data-controls-anchor]")?.getAttribute("data-controls-anchor");
  if (arm !== "first-line" && under[1]! > box.height / 3)
    throw new Error(`Send stands ${under[1]} px over the bottom of a ${box.height} px box: not on its bottom edge`);
}

const scene = (
  note: string,
  play?: (ctx: PlayContext) => Promise<void>,
  fields: Partial<AgentPaneVariant> = {},
): AgentPaneVariant => ({
  composerLook: "claude",
  note,
  snapshot: chat(finished),
  native: {
    "chat.attach.dropped": {
      items: [
        { path: SCREENSHOT_PATH, folder: false },
        { path: VIDEO_PATH, folder: false },
      ],
    },
    "video.info": VIDEO_INFO,
    "video.frames": { frames: [] },
  },
  ...(play ? { play } : {}),
  ...fields,
});

export default agentPaneEntry({
  id: "agent-pane.composer-controls-anchor",
  title: "Composer controls anchor",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 400, normal: 760, wide: 760 },
  covers: ["agent-session/acpmux/ComposerBox.tsx#ComposerBox"],
  keywords: ["composer", "send", "plus", "mic", "bottom", "attachments", "multi-line"],
  variants: {
    empty: scene("Nothing in the prompt: one line, + on the left and the mic on the right, as before in every arm."),
    "one-attachment": scene(
      "A screen recording dropped in the prompt over its words: + and the mic stand on the box's bottom edge, beside the words.",
      async (ctx) => {
        await drop(ctx, ["video"]);
        checkBottom(ctx);
      },
      { ready: { draft: "the hover preview bounces for some reason" } },
    ),
    "three-attachments": scene(
      "Leo's prompt: a screenshot, a screen recording and a pasted log in the prompt, then his words. + and Send stand on the bottom edge, not level with the tiles' top.",
      async (ctx) => {
        await drop(ctx, ["screenshot", "video"]);
        await pasteLog(ctx);
        checkBottom(ctx);
      },
      {
        ready: {
          draft: "the hover preview bounces for some reason\nand the buttons should be at the bottom of the composer",
        },
      },
    ),
    "multi-line": scene(
      "A four-line draft: + and Send stand beside its last line.",
      async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-md")?.textContent?.includes("fourth"));
        checkBottom(ctx);
      },
      {
        ready: {
          draft:
            "first line of the plan\nsecond line: what changes\nthird line: how we check it\nfourth line: who to tell",
        },
      },
    ),
  },
  experiment: {
    definition: composerControlsAnchor,
    script: [
      {
        name: "Drop Leo's screenshot, recording and log",
        run: async (ctx) => {
          await drop(ctx, ["screenshot", "video"]);
          await pasteLog(ctx);
        },
      },
    ],
  },
});
