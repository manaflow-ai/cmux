// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// Images in a reply (Markdown.tsx draws a data URL image inline; a click opens ImageViewer.tsx over
// the pane, with arrows through every image of the chat).
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { screenMock } from "../mockFixture";

const image = (alt: string, theme: "light" | "dark", title: string) =>
  `![${alt}](data:image/svg+xml;base64,${btoa(screenMock(theme, title))})`;

const replyImages = () =>
  chat(
    [
      user("Add light theme screenshots", 8),
      assistant(
        [
          "Captured the settings and billing screens in both themes.",
          image("Settings, light", "light", "Settings"),
          image("Settings, dark", "dark", "Settings"),
          image("Billing, light", "light", "Billing"),
        ].join("\n\n"),
        7,
      ),
      summary(7, { status: "completed" }),
    ],
    { title: "Add light theme screenshots" },
  );

export default agentPaneEntry({
  id: "agent-pane.image-viewer",
  title: "Image viewer",
  area: "Agent pane",
  covers: ["agent-session/acpmux/conversation/ImageViewer.tsx"],
  // The viewer opens over the pane; nothing under it moves.
  anchors: [{ selector: ".acpmux-composer" }, { selector: ".acpmux-header" }, { selector: ".acpmux-scroll" }],
  variants: {
    "reply-images": {
      note: "A reply with three screenshots; each opens the viewer.",
      snapshot: replyImages(),
    },
    open: {
      note: "Play: click the first image; the viewer shows it with its place, Copy and Close.",
      snapshot: replyImages(),
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Settings, light" });
        await ctx.waitFor(() => ctx.find({ role: "dialog", name: "Settings, light" }));
      },
    },
    next: {
      note: "Play: open the first image, then Next image; the viewer shows the second of three.",
      snapshot: replyImages(),
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Settings, light" });
        await ctx.click({ role: "button", name: "Next image" });
        await ctx.waitFor(() => ctx.find({ role: "dialog", name: "Settings, dark" }));
      },
    },
    zoomed: {
      note: "Play: open the first image and press +; it doubles about the center.",
      snapshot: replyImages(),
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Settings, light" });
        await ctx.waitFor(() => ctx.find({ role: "dialog", name: "Settings, light" }));
        await ctx.press("+");
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-image-viewer-stage.is-zoomed"));
      },
    },
    "across-turns": {
      note: "Images in two replies: the viewer's arrows go through both.",
      snapshot: chat(
        [
          user("Show the settings screen before the change", 12),
          assistant(`Before:\n\n${image("Settings, before", "dark", "Settings")}`, 11),
          summary(11, { status: "completed" }),
          user("And after", 6),
          assistant(`After, with the new rows:\n\n${image("Settings, after", "light", "Settings")}`, 5),
          summary(5, { status: "completed" }),
        ],
        { title: "Settings before and after" },
      ),
    },
  },
});
