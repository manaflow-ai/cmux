// l10n-allow-file: gallery fixtures (sample browsers and URLs), not shipped UI.
import { createElement } from "react";
import { componentEntry, type ChipHostFixture } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";

type OpenInMenuProps = { url: string };
const browsers: NonNullable<ChipHostFixture["browsers"]> = [
  { id: "safari", name: "Safari", icon: "data:image/png;base64,AA==" },
  { id: "firefox", name: "Firefox" },
  { id: "chrome", name: "Google Chrome" },
];
const chipHost: ChipHostFixture = { browsers };
const openMenu: Play = async (ctx) => {
  await ctx.focus({ selector: ".acpmux-open-in" });
  await ctx.press("Enter");
  await ctx.waitFor(() => (ctx.document.querySelectorAll(".ui-menu-item").length >= 5 ? true : null));
};

export default componentEntry<OpenInMenuProps>({
  id: "agent-pane.open-in-menu",
  title: "Open in menu",
  area: "Agent pane",
  covers: ["agent-session/acpmux/previewCard/OpenInMenu.tsx#OpenInMenu"],
  load: async () => {
    const { OpenInMenu } = await import("./OpenInMenu");
    return function GalleryOpenInMenu({ url }: OpenInMenuProps) {
      return createElement(OpenInMenu, { url, onOpenInPane: () => {} });
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("../chips/chips.css"), import("./previewCard.css")]),
  checks: {
    longFrameFailMs: {
      value: 120,
      reason: "Opening the real Base UI menu positions its portal and browser rows in one software-VM frame.",
    },
  },
  variants: {
    closed: { chipHost, props: { url: "https://docs.example.test/guide" } },
    "several-browsers": {
      note: "cmux browser, then the installed browser list and Copy link.",
      chipHost,
      props: { url: "https://docs.example.test/guide" },
      play: openMenu,
    },
  },
});
