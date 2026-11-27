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
// opacity over a dimmed backdrop (Leo, 2026-11-05: "this screenshot preview has too much opacity and the file
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
  // The row's layout settles before the click, so the click's step measures only the viewer opening.
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-stage[data-solo-tab] > .acpmux-scroll .acpmux-row"));
  await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
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
  lightbox(doc);
};

// A lightbox, as Quick Look is (Leo, 2026-11-27: "ok the screenshots thing needs to not opaque out everything
// else. just have what normal standards are for this. some lowered opaity?"): a clear popup over a backdrop
// dimmed 40-50% black, the image drawn at its own size unless larger than the stage, and a bar narrower
// than the viewer. Chromium computes colors as `color(srgb r g b / a)`, other engines as `rgba(r, g, b, a)`.
const alphaOf = (color: string) => {
  if (color === "transparent") return 0;
  const match = /(?:\/|,\s*[\d.]+\s*,\s*[\d.]+\s*,)\s*([\d.]+)\s*\)$/.exec(color);
  return match ? Number(match[1]) : 1;
};
function lightbox(doc: Document): void {
  const view = doc.defaultView!;
  const viewer = doc.querySelector<HTMLElement>(".acpmux-image-viewer")!;
  const popup = alphaOf(view.getComputedStyle(viewer).backgroundColor);
  if (popup > 0) throw new Error(`The viewer's popup paints a ${popup} opaque surface over the chat`);
  const backdrop = doc.querySelector<HTMLElement>(".acpmux-image-viewer-backdrop")!;
  const dim = alphaOf(view.getComputedStyle(backdrop).backgroundColor);
  if (dim < 0.35 || dim > 0.55) throw new Error(`The backdrop dims ${dim}, not the lightbox's 40-50%`);
  const bar = doc.querySelector<HTMLElement>(".acpmux-image-viewer-bar")!.getBoundingClientRect();
  const frame = viewer.getBoundingClientRect();
  if (bar.width >= frame.width * 0.9) throw new Error(`The bar is ${bar.width}px of ${frame.width}px: a header`);
  const img = doc.querySelector<HTMLImageElement>(".acpmux-image-viewer-image")!;
  const box = img.getBoundingClientRect();
  if (!img.complete || img.naturalWidth === 0 || box.width < 1 || box.height < 1)
    throw new Error(`The image does not draw (${box.width}x${box.height}, natural ${img.naturalWidth})`);
  const stage = img.parentElement!.getBoundingClientRect();
  const fits = img.naturalWidth <= stage.width - 112 && img.naturalHeight <= stage.height - 80;
  if (fits && Math.abs(box.width - img.naturalWidth) > 1)
    throw new Error(`A ${img.naturalWidth}px image that fits draws ${box.width}px wide, not at its own size`);
  if (box.right > stage.right || box.bottom > stage.bottom || box.left < stage.left || box.top < stage.top)
    throw new Error("The image runs past the stage instead of shrinking to fit");
}

// Leo's pasted screenshot: wide and short, smaller than the pane, so it draws at its own size.
const wideName = "Screenshot · 1042×216";
const wideScreenshot = () =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="521" height="108" viewBox="0 0 521 108"><rect width="521" height="108" fill="#1f2937"/><rect x="12" y="12" width="497" height="28" rx="6" fill="#374151"/><rect x="12" y="52" width="320" height="12" rx="3" fill="#9ca3af"/><rect x="12" y="74" width="420" height="12" rx="3" fill="#6b7280"/></svg>`;
// Larger than any pane: shrinks to fit.
const largeName = "Screenshot · 4000×2600";
const largeScreenshot = () =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="4000" height="2600" viewBox="0 0 4000 2600"><rect width="4000" height="2600" fill="#0ea5e9"/><circle cx="2000" cy="1300" r="900" fill="#f8fafc"/></svg>`;
const shotChat = (alt: string, svg: string) =>
  chat(
    [
      user("Screenshot the settings row", 8),
      assistant(["Here it is; the second row is cut off at the right edge.", image(alt, svg)].join("\n\n"), 7),
      summary(7, { status: "completed" }),
    ],
    { title: "Check the screenshot" },
  );
const openShot =
  (alt: string): Play =>
  async (ctx) => {
    await ctx.click({ role: "button", name: alt });
    await ctx.waitFor(() => ctx.find({ role: "dialog", name: alt }));
    await ctx.waitFor(() => ctx.document.querySelector<HTMLImageElement>(".acpmux-image-viewer-image")?.complete);
    lightbox(ctx.document);
  };
const closesBy =
  (how: "space" | "outside"): Play =>
  async (ctx) => {
    await openShot(wideName)(ctx);
    if (how === "space") await ctx.press(" ");
    else {
      const stage = ctx.document.querySelector<HTMLElement>(".acpmux-image-viewer-stage")!;
      stage.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }));
      stage.click();
    }
    await ctx.waitFor(() => !ctx.document.querySelector('[role="dialog"]'));
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
    "lightbox-wide-screenshot": {
      note: "Play: Leo's wide, short pasted screenshot opens at its own size, centered over the dimmed chat, with a small floating bar.",
      snapshot: shotChat(wideName, wideScreenshot()),
      play: openShot(wideName),
    },
    "lightbox-large-image": {
      note: "Play: an image larger than the pane shrinks to fit the stage, still over the dimmed chat.",
      snapshot: shotChat(largeName, largeScreenshot()),
      play: openShot(largeName),
    },
    "lightbox-space-closes": {
      note: "Play: open the screenshot, then Space closes it, as Quick Look does.",
      snapshot: shotChat(wideName, wideScreenshot()),
      play: closesBy("space"),
    },
    "lightbox-click-outside-closes": {
      note: "Play: open the screenshot, then a click beside the image closes it.",
      snapshot: shotChat(wideName, wideScreenshot()),
      play: closesBy("outside"),
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
