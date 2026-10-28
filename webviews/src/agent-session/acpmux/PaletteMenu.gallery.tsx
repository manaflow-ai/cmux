// l10n-allow-file: gallery fixtures for the command palette menu.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { PaletteMenu, paletteSections } from "./PaletteMenu";
import { nativeComposerExtensions } from "./composerPlusRegistry";
import { useT } from "./i18n";

const open: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-picker-button" });
};

function Fixture({ variant }: { variant: string }) {
  const t = useT();
  // Catalog-shaped fixture rows; the rendered component and dispatch path are the real + menu.
  const sections = paletteSections(
    () => undefined,
    t,
    nativeComposerExtensions([
      {
        id: "openBrowser",
        section: "tools",
        name: "New Browser Tab",
        description: "Open a browser tab",
        icon: "globe",
      },
      {
        id: "newSurface",
        section: "tools",
        name: "New Terminal",
        description: "Open a terminal tab",
        icon: "terminal",
      },
      {
        id: "app.command.run",
        section: "apps",
        name: "Run App Command",
        description: "Choose an app command",
        icon: "square.grid.2x2",
      },
      {
        id: "search.chats",
        section: "sessions",
        name: "Search Chats",
        description: "Find a recent conversation",
        icon: "bubble.left",
      },
      {
        id: "tab.search",
        section: "tabs",
        name: "Search Tabs",
        description: "Find an open tab",
        icon: "square.on.square",
      },
    ]),
  ).filter(
    (section) =>
      variant === "balanced" ||
      (variant === "tools" ? ["Tools", "Apps"].includes(section.title) : ["Sessions", "Tabs"].includes(section.title)),
  );
  return (
    <div
      style={{
        height: "100%",
        boxSizing: "border-box",
        padding: 24,
        display: "flex",
        justifyContent: "center",
        alignItems: "flex-end",
      }}
    >
      <PaletteMenu label="Add" button={<span aria-hidden>+</span>} sections={sections} />
    </div>
  );
}

export default componentEntry<{ variant: string }>({
  id: "agent-pane.composer-plus-menu",
  title: "Composer plus: tools, apps, sessions and tabs",
  area: "Agent pane",
  pane: true,
  height: 560,
  widths: { narrow: 360, normal: 520, wide: 760 },
  anchors: [{ selector: ".acpmux-picker-button" }],
  checks: {
    anchorMovePx: { value: 0, reason: "The menu is portaled from a stable + trigger." },
    layoutShiftMax: { value: 0, reason: "Opening the floating menu must not shift its trigger or popup content." },
  },
  covers: ["agent-session/acpmux/PaletteMenu.tsx#PaletteMenu"],
  styles: () => import("./styles.css"),
  load: async () => Fixture,
  variants: {
    balanced: {
      note: "Chat and New Tab share one searchable registry-backed menu.",
      props: { variant: "balanced" },
      play: open,
    },
    tools: {
      note: "Tools and connected apps stay grouped with descriptions.",
      props: { variant: "tools" },
      play: open,
    },
    sessions: {
      note: "Sessions and tabs open the native search entry points; selecting a specific item as prompt context follows in a separate change.",
      props: { variant: "sessions" },
      play: open,
    },
  },
});
