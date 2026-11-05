// l10n-allow-file: gallery fixtures for the command palette menu.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { PaletteMenu, paletteSections } from "./PaletteMenu";
import { nativeComposerExtensions } from "./composerPlusRegistry";
import { useT } from "./i18n";

const open: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-picker-button" });
};

const editSearch: Play = async (ctx) => {
  await open(ctx);
  const input = ctx.find({ role: "combobox" }) as HTMLInputElement;
  const initial = input.getBoundingClientRect();
  const assertSearchAnchor = () => {
    const current = input.getBoundingClientRect();
    const dimensions = ["top", "left", "width", "height"] as const;
    if (dimensions.some((key) => current[key] !== initial[key]))
      throw new Error("Filtering moved or resized the palette search field");
  };
  await ctx.type("browser", { role: "combobox" });
  assertSearchAnchor();
  const selected = input.getAttribute("aria-activedescendant");
  await ctx.press("Home");
  await ctx.waitFor(() => input.selectionStart === 0 && input.selectionEnd === 0);
  await ctx.press("Shift+End");
  await ctx.waitFor(() => input.selectionStart === 0 && input.selectionEnd === input.value.length);
  await ctx.press("End");
  await ctx.waitFor(() => input.selectionStart === input.value.length && input.selectionEnd === input.value.length);
  await ctx.press("Shift+Home");
  await ctx.waitFor(() => input.selectionStart === 0 && input.selectionEnd === input.value.length);
  await ctx.waitFor(() => input.getAttribute("aria-activedescendant") === selected);
  await ctx.press("Backspace");
  assertSearchAnchor();
  await ctx.type("no matching item", { role: "combobox" });
  assertSearchAnchor();
};

type PaletteMenuVariant = "keyboard" | "balanced" | "tools" | "sessions";

function Fixture({ variant }: { variant: PaletteMenuVariant }) {
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
    ]).filter(
      (entry) =>
        variant === "balanced" ||
        variant === "keyboard" ||
        (variant === "tools"
          ? entry.section === "tools" || entry.section === "apps"
          : entry.section === "sessions" || entry.section === "tabs"),
    ),
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

export default componentEntry<{ variant: PaletteMenuVariant }>({
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
    keyboard: {
      note: "Home and End, including Shift selection, edit search instead of navigating menu rows.",
      props: { variant: "keyboard" },
      play: editSearch,
    },
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
