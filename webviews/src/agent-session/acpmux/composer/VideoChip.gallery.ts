// l10n-allow-file: gallery fixtures (sample chats and files), not shipped UI.
// A screen recording pasted into the composer (Leo 2026-10-22: "also teh screen reccording preview is
// just a file name idk if we can do better maybe"): the chip shows the video's poster frame, a play
// glyph and its length, beside a screenshot's image chip. The real pane takes a real paste: the
// host knows where the files are (chat.attach.dropped), so the video goes as a link to its path,
// and the page draws its poster from the pasted File (composer/videoPoster.ts). `video-frame` is
// the shipped look; `video-strip` and `video-square` are the looks it was picked over, drawn by a
// stylesheet the play adds (they ship no code).
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { LOGIN_SCREENSHOT_PNG } from "../../../gallery/fixtures/toolImages";
import { COLOR_BARS_MOV } from "../../../gallery/fixtures/videoFixtures";
import type { PlayContext } from "../../../gallery/play";

const RECORDING = "Screen Recording 2026-10-22 at 21.41.07.mov";
const DESKTOP = "/Users/you/Desktop";

const snapshot = chat([
  user("The sidebar flickers when a chat finishes", 6),
  assistant("I could not reproduce it from the logs. A recording of it would help.", 5),
  summary(5, { status: "completed" }),
]);

/// The two looks the shipped one was picked over: the frame with the name beside it (as the PDF
/// chip names its sheet), and a square frame with its length under it.
const LOOKS = `
.acpmux-attachment-video[data-look="strip"] {
  display: flex; align-items: center; max-width: min(260px, 72vw); overflow: hidden;
}
.acpmux-attachment-video[data-look="strip"] .acpmux-attachment-video-frame { flex: none; }
.acpmux-attachment-video[data-look="strip"] .acpmux-attachment-video-frame img { max-width: 114px; }
.acpmux-attachment-video-name {
  min-width: 0; padding: 0 26px 0 10px; color: var(--agent-text);
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.acpmux-attachment-video[data-look="square"] .acpmux-attachment-video-frame {
  display: grid; grid-template-rows: 1fr auto; place-items: center; width: 64px;
}
.acpmux-attachment-video[data-look="square"] .acpmux-attachment-video-frame img {
  width: 64px; min-width: 0; height: 46px;
  border-radius: var(--acpmux-attach-radius) var(--acpmux-attach-radius) 0 0;
}
.acpmux-attachment-video[data-look="square"] .acpmux-attachment-video-play { bottom: 18px; }
.acpmux-attachment-video[data-look="square"] .acpmux-attachment-video-length {
  position: static; background: none; color: var(--agent-muted);
}
`;

/// Pastes `files` into the prompt as the browser does, with a real DataTransfer.
function paste(ctx: PlayContext, files: File[]): void {
  const view = ctx.document.defaultView!;
  const data = new view.DataTransfer();
  for (const file of files) data.items.add(file);
  const event = new view.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: data });
  ctx.find({ selector: ".acpmux-md" }).dispatchEvent(event);
}

/// Pastes a screenshot and the recording; with `look`, draws the video chip in that look.
const pasteRecording =
  (look?: "strip" | "square", bytes = COLOR_BARS_MOV) =>
  async (ctx: PlayContext): Promise<void> => {
    const view = ctx.document.defaultView!;
    const decode = (base64: string) => Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
    paste(ctx, [
      new view.File([decode(LOGIN_SCREENSHOT_PNG)], "Screenshot 2026-10-22 at 21.40.12.png", { type: "image/png" }),
      new view.File([decode(bytes)], RECORDING, { type: "video/quicktime" }),
    ]);
    if (bytes !== COLOR_BARS_MOV) {
      await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-link:not([aria-busy])"));
      return;
    }
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-video-frame img[src^='data:image/jpeg']"));
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-image img"));
    if (!look) return;
    const style = ctx.document.createElement("style");
    style.textContent = LOOKS;
    ctx.document.head.append(style);
    const chip = ctx.find({ selector: ".acpmux-attachment-video" });
    chip.setAttribute("data-look", look);
    if (look !== "strip") return;
    const name = ctx.document.createElement("span");
    name.className = "acpmux-attachment-video-name";
    name.textContent = RECORDING;
    chip.querySelector(".acpmux-attachment-video-frame")!.after(name);
  };

const native = {
  "chat.attach.dropped": {
    items: [
      { path: `${DESKTOP}/Screenshot 2026-10-22 at 21.40.12.png`, folder: false },
      { path: `${DESKTOP}/${RECORDING}`, folder: false },
    ],
  },
};

export default agentPaneEntry({
  id: "agent-pane.composer-video-chip",
  title: "Composer video chip",
  area: "Agent pane",
  height: 360,
  widths: { narrow: 400, normal: 760, wide: 760 },
  covers: ["agent-session/acpmux/composer/attachmentIntake.tsx#AttachmentStrip"],
  variants: {
    "video-frame": {
      note: "Shipped: the poster frame as a tile like the screenshot's, a play glyph and its length; the name on hover.",
      snapshot,
      native,
      play: pasteRecording(),
    },
    "video-strip": {
      note: "Considered: the frame with the name beside it, as the PDF chip names its sheet.",
      snapshot,
      native,
      play: pasteRecording("strip"),
    },
    "video-square": {
      note: "Considered: a square frame with its length under it.",
      snapshot,
      native,
      play: pasteRecording("square"),
    },
    "video-undecodable": {
      note: "A video the engine cannot decode keeps today's file chip, its name and path.",
      snapshot,
      native,
      play: pasteRecording(undefined, btoa(String.fromCharCode(0, 0, 0, 0x18, 0xff))),
    },
  },
});
