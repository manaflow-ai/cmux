// l10n-allow-file: gallery fixtures (sample chat actions), not shipped UI.
// The chat header's consolidated top-right layouts (Debug Settings `agentChat.topRight.consolidate`,
// TopRightLayouts.tsx), each beside today's row, at rest, mid-use and with a pane open. The plays set
// the layout and the open panes the way the App pushes them (headerState) and click as a person does.
import { createElement } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play, PlayContext } from "../../../gallery/play";
import type { ChatMenuItem } from "./ChatHeaderTools";
import { PanelToggle } from "./PanelToggle";
import type { TopRightLayout } from "./topRightLayout";

type Props = Parameters<typeof import("./ChatHeaderTools").ChatHeaderTools>[0];

const menuRows = (): ChatMenuItem[] => [
  { key: "rename", label: "Rename", icon: "action.edit", onSelect: () => undefined },
  { key: "fork", label: "Fork", icon: "agent.fork", onSelect: () => undefined },
];

const base: Props = {
  onTerminal: () => undefined,
  onBrowser: () => undefined,
  onSplitDown: () => undefined,
  onFiles: () => undefined,
  hasChanges: true,
  onChanges: () => undefined,
  summary: createElement(PanelToggle, {
    className: "acpmux-summary-button",
    label: "Chat summary",
    shown: false,
    onToggle: () => undefined,
  }),
  menu: menuRows,
  onMenuOpen: async () => undefined,
};

// Terminal's split (`splitRight`), Browser's (`splitBrowserRight`), Changes' diff (`openDiffViewer`).
async function layout(ctx: PlayContext, value: TopRightLayout, lit: string[] = [], recent: string[] = []) {
  const [{ setHeaderState, headerState }, { resetRecentPanes }] = await Promise.all([
    import("./headerState"),
    import("./topRightLayout"),
  ]);
  resetRecentPanes(recent as never);
  setHeaderState({ topRightLayout: value, lit, version: headerState().version + 1 });
  await ctx.waitFor(() =>
    value === "row"
      ? ctx.document.querySelector(".acpmux-header-tools:not([data-top-right]) [data-quick-action]")
      : ctx.document.querySelector(`.acpmux-header-tools[data-top-right="${value}"]`),
  );
}

const settle = (ctx: PlayContext) => new Promise((done) => ctx.document.defaultView!.setTimeout(done, 400));

const at =
  (value: TopRightLayout, lit: string[] = [], recent: string[] = []): Play =>
  async (ctx) =>
    layout(ctx, value, lit, recent);

const morphOpen: Play = async (ctx) => {
  await layout(ctx, "morph");
  await ctx.click({ selector: ".acpmux-topright-morph-trigger" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-topright-morph[data-open]"));
  await settle(ctx);
  const set = ctx.find({ selector: ".acpmux-topright-morph-set" });
  if (set.querySelectorAll("button").length < 3) throw new Error("the morph set must hold every quick action");
  const title = ctx.document.querySelector(".acpmux-header-tools")!.getBoundingClientRect();
  if (Math.round(title.width) === 0) throw new Error("the header tools collapsed");
};

// Pick Terminal from the expanded set: the set closes and the control wears Terminal's glyph, lit,
// while its split is open (the App lights `splitRight` once it opens).
const morphPicked: Play = async (ctx) => {
  await morphOpen(ctx);
  await ctx.click({ selector: '.acpmux-topright-morph-set [data-quick-action="terminal"]' });
  const { setHeaderState, headerState } = await import("./headerState");
  setHeaderState({ lit: ["splitRight"], version: headerState().version + 1 });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-topright-morph-trigger[data-face="terminal"]'));
  if (ctx.document.querySelector(".acpmux-topright-morph[data-open]")) throw new Error("a pick must close the set");
  await settle(ctx);
};

// Two panes open: the control wears the last pick, and its circle counts both.
const morphTwoOpen: Play = async (ctx) => {
  await layout(ctx, "morph", ["splitRight", "openDiffViewer"], ["changes", "terminal"]);
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-topright-morph-trigger[data-face="changes"]'));
  const count = ctx.find({ selector: ".acpmux-topright-count" });
  const box = count.getBoundingClientRect();
  if (Math.abs(box.width - box.height) > 0.5) throw new Error("the count badge must be a circle, not a pill");
};

const stripDocked: Play = async (ctx) => {
  await layout(ctx, "tabStrip", ["splitRight"], ["terminal"]);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-topright-strip[data-docked] .acpmux-topright-tab"));
  await settle(ctx);
  const tools = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-header-tools > *")];
  const right = (el: Element) => el.getBoundingClientRect().right;
  const tab = ctx.find({ selector: ".acpmux-topright-tab" });
  if (tools.some((el) => right(el) > right(tab) + 0.5))
    throw new Error("the open pane's tab must be the trailing control");
};

const dockOpen =
  (lit: string[], recent: string[]): Play =>
  async (ctx) => {
    await layout(ctx, "dock", lit, recent);
    await ctx.click({ role: "button", name: "Recent Panes" });
    await ctx.waitFor(() => ctx.document.querySelector('[role="menu"] .acpmux-topright-dock-row'));
  };

export default componentEntry<Props>({
  id: "agent-pane.top-right-layouts",
  title: "Chat header: consolidated top-right layouts",
  area: "Agent pane",
  height: 360,
  widths: { narrow: 390, normal: 560, wide: 860 },
  anchors: [{ selector: ".acpmux-header-tools" }],
  covers: [
    "agent-session/acpmux/header/TopRightLayouts.tsx#TopRightLayouts",
    "agent-session/acpmux/header/ChatHeaderTools.tsx#ChatHeaderTools",
  ],
  load: () =>
    import("./ChatHeaderTools").then((module) => (props: Props) => createElement(module.ChatHeaderTools, props)),
  styles: () => Promise.all([import("../styles.css"), import("../../../ui/popupSurface.css"), import("./header.css")]),
  variants: {
    "row-today": {
      note: "Today's row (the default, unchanged): every quick action its own button.",
      props: base,
      play: at("row"),
    },
    "morph-rest": {
      note: "Morph at rest: one control in the row's place; nothing open beside the chat.",
      props: base,
      play: at("morph"),
    },
    "morph-open": {
      note: "Morph expanded: the control grows leftward into the set, every quick action in reach, the control still at the trailing edge.",
      props: base,
      play: morphOpen,
    },
    "morph-picked": {
      note: "Terminal picked: the set closes and the control becomes Terminal's glyph, lit, while its pane is open.",
      props: base,
      play: morphPicked,
    },
    "morph-two-open": {
      note: "Two panes open: the control wears the last pick and a circle counts the open panes.",
      props: base,
      play: morphTwoOpen,
    },
    "strip-rest": {
      note: "Tab strip with nothing open: today's row.",
      props: base,
      play: at("tabStrip"),
    },
    "strip-docked": {
      note: "Tab strip with Terminal open: its icon is a tab at the trailing edge, standing on the header's bottom edge against the right pane's strip; the rest sit before it.",
      props: base,
      play: stripDocked,
    },
    "dock-rest": {
      note: "Dock: one recent-panes button; a circle counts the open panes.",
      props: base,
      play: at("dock", ["splitRight"], ["terminal"]),
    },
    "dock-open": {
      note: "Dock open: Terminal open now, Browser opened before and closed, then the rest.",
      props: base,
      play: dockOpen(["splitRight"], ["terminal", "browser"]),
    },
  },
});
