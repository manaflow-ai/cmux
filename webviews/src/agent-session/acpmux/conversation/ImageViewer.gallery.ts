// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// Images in a reply (Markdown.tsx draws a data URL image inline; a click opens ImageViewer.tsx over
// the pane, with arrows through every image of the chat). The opened viewer's states are play
// steps on the same reply.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { sampleChart, sampleDiagram, sampleGradient } from "../mockFixture";

const image = (alt: string, svg: string) => `![${alt}](data:image/svg+xml;base64,${btoa(svg)})`;

const replyImages = () =>
  chat(
    [
      user("Make sample images for the docs", 8),
      assistant(
        [
          "Made three sample images: a chart, a gradient and a diagram.",
          image("Weekly builds", sampleChart()),
          image("Dusk gradient", sampleGradient()),
          image("Request flow", sampleDiagram()),
        ].join("\n\n"),
        7,
      ),
      summary(7, { status: "completed" }),
    ],
    { title: "Make sample images for the docs" },
  );

// A pasted screenshot's name (imageLabel.ts) in a one-tab pane whose native tab row floats over the page's top
// (header/tabRow.ts). The viewer opens below the row, its name inside its own bar, and the image draws at full
// opacity over a light backdrop (Leo, 2026-11-05: "this screenshot preview has too much opacity and the file
// nameis also way at the top").
const screenshotName = "Screenshot · 1568×674";
const pastedScreenshot = () =>
  chat(
    [
      user("What does this chart say?", 8),
      assistant(["The builds dip midweek.", image(screenshotName, sampleChart())].join("\n\n"), 7),
      summary(7, { status: "completed" }),
    ],
    { title: "Read the build chart" },
  );
const ROW = 38;
const underTabRow: Play = async (ctx) => {
  const { setTabRow } = await import("../header/tabRow");
  setTabRow({ height: ROW, trailingInset: 0, soloTab: true });
  await ctx.click({ role: "button", name: screenshotName });
  await ctx.waitFor(() => ctx.find({ role: "dialog", name: screenshotName }));
  const doc = ctx.document;
  const view = doc.defaultView!;
  const viewer = doc.querySelector<HTMLElement>(".acpmux-image-viewer")!;
  const bar = doc.querySelector<HTMLElement>(".acpmux-image-viewer-bar")!.getBoundingClientRect();
  const title = doc.querySelector<HTMLElement>(".acpmux-image-viewer-title")!.getBoundingClientRect();
  const frame = viewer.getBoundingClientRect();
  if (frame.top < ROW) throw new Error(`The viewer starts at ${frame.top}px, under the ${ROW}px tab row`);
  if (title.top < ROW || title.top < frame.top || title.bottom > bar.bottom)
    throw new Error(
      `The image's name (${title.top}-${title.bottom}px) is not inside the viewer's bar below the tab row`,
    );
  const img = doc.querySelector<HTMLImageElement>(".acpmux-image-viewer-image")!;
  for (let node: HTMLElement | null = img; node; node = node.parentElement) {
    const style = view.getComputedStyle(node);
    if (Number(style.opacity) !== 1 || style.filter !== "none")
      throw new Error(
        `The image is dimmed by ${node.className || node.tagName} (opacity ${style.opacity}, filter ${style.filter})`,
      );
  }
  // The backdrop is light: the surface mix leaves the pane showing through. Chromium computes the mix as
  // `color(srgb r g b / a)`, other engines as `rgba(r, g, b, a)`; no alpha is opaque.
  const background = view.getComputedStyle(viewer).backgroundColor;
  const alpha = Number(/(?:\/|,\s*[\d.]+\s*,\s*[\d.]+\s*,)\s*([\d.]+)\s*\)$/.exec(background)?.[1] ?? 1);
  if (alpha > 0.8) throw new Error(`The viewer's backdrop is ${alpha} opaque (${background})`);
};

export default agentPaneEntry({
  id: "agent-pane.image-viewer",
  title: "Image viewer",
  area: "Agent pane",
  covers: ["agent-session/acpmux/conversation/ImageViewer.tsx"],
  // The viewer opens over the pane; nothing under it moves.
  anchors: [{ selector: ".acpmux-composer" }, { selector: ".acpmux-header" }, { selector: ".acpmux-scroll" }],
  checks: {
    popupLayer: {
      value: true,
      reason: "The image viewer backdrop and dialog must stay the top, viewport-filling layer over the transcript.",
    },
    anchorMovePx: {
      value: 0,
      reason: "Opening or dismissing the viewer is portaled and must not move the transcript or composer anchors.",
    },
    settleMaxMs: {
      value: 250,
      reason: "Opening, stepping and dismissing an image viewer should settle within a quarter second.",
    },
  },
  variants: {
    "reply-images": {
      note: "A reply with three images; each opens the viewer.",
      snapshot: replyImages(),
    },
    open: {
      note: "Play: click the first image; the viewer shows it with its place, Copy and Close.",
      snapshot: replyImages(),
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Weekly builds" });
        await ctx.waitFor(() => ctx.find({ role: "dialog", name: "Weekly builds" }));
      },
    },
    next: {
      note: "Play: open the first image, then Next image; the viewer shows the second of three.",
      snapshot: replyImages(),
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Weekly builds" });
        await ctx.click({ role: "button", name: "Next image" });
        await ctx.waitFor(() => ctx.find({ role: "dialog", name: "Dusk gradient" }));
      },
    },
    zoomed: {
      note: "Play: open the first image and press +; it doubles about the center.",
      snapshot: replyImages(),
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Weekly builds" });
        await ctx.waitFor(() => ctx.find({ role: "dialog", name: "Weekly builds" }));
        await ctx.press("+");
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-image-viewer-stage.is-zoomed"));
      },
    },
    "dismiss-and-restore": {
      note: "Play: open the first reply image, step to the next image, then dismiss with Escape and restore focus to the opener.",
      snapshot: replyImages(),
      play: async (ctx) => {
        const opener = { role: "button", name: "Weekly builds" } as const;
        await ctx.click(opener);
        await ctx.waitFor(() => ctx.find({ role: "dialog", name: "Weekly builds" }));
        await ctx.click({ role: "button", name: "Next image" });
        await ctx.waitFor(() => ctx.find({ role: "dialog", name: "Dusk gradient" }));
        await ctx.press("Escape");
        await ctx.waitFor(
          () =>
            !ctx.document.querySelector('[role="dialog"]') &&
            ctx.document.activeElement === ctx.document.querySelector("button[data-open-image]"),
        );
      },
    },
    "pasted-screenshot-under-tab-row": {
      note: "Play: a one-tab pane's row floats over the page; the screenshot opens below it, its name in the viewer's bar, the image at full opacity.",
      snapshot: pastedScreenshot(),
      play: underTabRow,
    },
    "across-turns": {
      note: "Images in two replies: the viewer's arrows go through both.",
      snapshot: chat(
        [
          user("Chart this week's builds", 12),
          assistant(`Builds per day:\n\n${image("Weekly builds", sampleChart())}`, 11),
          summary(11, { status: "completed" }),
          user("Now draw the request flow", 6),
          assistant(`The request path:\n\n${image("Request flow", sampleDiagram())}`, 5),
          summary(5, { status: "completed" }),
        ],
        { title: "Build charts" },
      ),
    },
  },
});
