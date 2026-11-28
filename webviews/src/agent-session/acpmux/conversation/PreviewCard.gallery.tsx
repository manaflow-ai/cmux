// l10n-allow-file: gallery fixtures (sample web addresses), not shipped UI.
import { createElement } from "react";
import { componentEntry, type ChipHostFixture } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";

type PreviewCardProps = { url: string };
const docs = "https://docs.example.test/guide";
const loopback = "http://127.0.0.1:3000/admin?tab=1";
const favicon =
  "data:image/svg+xml," +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" rx="4" fill="#81b29a"/><path d="M4 11l3-6 2 3 2-2 2 5z" fill="#fff"/></svg>',
  );
const chipHost: ChipHostFixture = {
  sites: { [docs]: { title: "Example docs", icon: favicon } },
  browsers: [
    { id: "safari", name: "Safari", icon: "data:image/png;base64,AA==" },
    { id: "firefox", name: "Firefox" },
    { id: "chrome", name: "Google Chrome" },
  ],
};
const loadPreview: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-turn-preview-load" });
  await ctx.waitFor(() => ctx.document.querySelector("iframe"));
};
const openMenu: Play = async (ctx) => {
  await ctx.focus({ selector: ".acpmux-open-in" });
  await ctx.press("Enter");
  await ctx.waitFor(() => (ctx.document.querySelectorAll(".ui-menu-item").length >= 5 ? true : null));
};

export default componentEntry<PreviewCardProps>({
  id: "agent-pane.preview-card",
  title: "Web preview card",
  area: "Agent pane",
  covers: ["agent-session/acpmux/conversation/PreviewCard.tsx#PreviewCard"],
  load: async () => {
    const { PreviewCard } = await import("./PreviewCard");
    return function GalleryPreviewCard({ url }: PreviewCardProps) {
      return createElement(PreviewCard, { url, onOpen: () => {} });
    };
  },
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./conversation.css"),
      import("../chips/chips.css"),
      import("../previewCard/previewCard.css"),
    ]),
  checks: {
    longFrameFailMs: {
      value: 120,
      reason: "Opening the real Base UI menu positions its portal and browser rows in one software-VM frame.",
    },
  },
  widths: { narrow: 420, normal: 720, wide: 960 },
  variants: {
    "not-loaded": { chipHost, props: { url: docs } },
    loaded: { chipHost, props: { url: docs }, play: loadPreview },
    "open-in-menu": { chipHost, props: { url: docs }, play: openMenu },
    "loopback-host": {
      note: "A local dev server address remains unloaded until the reader clicks Load preview.",
      chipHost,
      props: { url: loopback },
    },
  },
});
