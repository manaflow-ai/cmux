// l10n-allow-file: gallery fixtures (sample chat actions), not shipped UI.
import { createElement, Fragment } from "react";
import type { ReactNode } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play, PlayContext } from "../../../gallery/play";
import { avatarRows } from "./avatarRow";
import { revokeAccessRows } from "./grantsMenu";
import { cloudMachineRows } from "../cloudMachineMenu";
import { translate } from "../i18n";
import type { ChatMenuItem } from "./ChatHeaderTools";
import { PanelToggle } from "./PanelToggle";
import type { QuickAction } from "./quickActions";
import type { NativeRowToolsHost } from "./useNativeRowTools";
import { NeedsYouButton } from "../needsYou/NeedsYou";

type HeaderToolsProps = {
  /// `more`: the chat menu ⋮'s box width; the rest of the tool size stays at its trailing side.
  /// The tools' square and gap as CSS lengths (header.css --acpmux-header-tool-size and -gap).
  treatment?: { size: string; gap: string };
  onTerminal: (mode: "toggle" | "open") => void;
  onSplitDown?: (mode: "toggle" | "open") => void;
  onBrowser: (mode: "toggle" | "open") => void;
  tabTools?: boolean;
  sideTabs?: boolean;
  onSideTabs?: () => void;
  onFiles?: (mode: "toggle" | "open") => void;
  hasChanges?: boolean;
  onChanges?: (mode: "toggle" | "open") => void;
  previewUrl?: string;
  onPreview?: (url: string | undefined, mode: "toggle" | "open") => void;
  onCustomize?: (list: readonly QuickAction[]) => void;
  summary: ReactNode;
  inbox?: ReactNode;
  nativeRowTools?: NativeRowToolsHost;
  menu: () => ChatMenuItem[];
  onMenuOpen?: () => Promise<unknown>;
  onMergePullRequest?: (pullRequest: { number: number; url: string }) => Promise<{ queued: boolean }>;
  expand?: string;
  onExpanded?: () => void;
  folder?: string;
  readStatus?: () => Promise<unknown>;
  onApplyWorktree?: (key: string) => Promise<unknown>;
  onRemoveWorktree?: (key: string, discard: boolean) => Promise<unknown>;
  working?: boolean;
  motion?: "still" | "animated-cue" | "animated-spring" | "animated-morph";
};

const menuRows = (): ChatMenuItem[] => [
  { key: "rename", label: "Rename", icon: "action.edit", shortcutAction: "renameTab", onSelect: () => undefined },
  {
    key: "pin",
    label: "Pin",
    icon: "action.pin",
    shortcutAction: "palette.toggleTabPin",
    onSelect: () => undefined,
  },
  "separator",
  { key: "sideChat", label: "New side chat", icon: "agent.chat.new", onSelect: () => undefined },
  { key: "fork", label: "Fork", icon: "agent.fork", onSelect: () => undefined },
  { key: "forkTo", label: "Fork to…", icon: "agent.fork", onSelect: () => undefined },
  "separator",
  {
    key: "continue",
    label: "Hand off to…",
    icon: "agent.handoff",
    children: [
      { key: "codex", label: "Codex", onSelect: () => undefined },
      { key: "claude", label: "Claude Code", onSelect: () => undefined },
    ],
  },
  "separator",
  {
    key: "copy",
    label: "Copy",
    icon: "action.copy",
    children: [
      { key: "copyLink", label: "Copy link", shortcutAction: "palette.copySurfaceLink", onSelect: () => undefined },
      { key: "copyResponse", label: "Copy last response", onSelect: () => undefined },
      { key: "copyMarkdown", label: "Copy as Markdown", onSelect: () => undefined },
      { key: "saveMarkdown", label: "Save as Markdown…", onSelect: () => undefined },
    ],
  },
  "separator",
  { key: "move-right", label: "Move to right pane", icon: "pane.split.right", onSelect: () => undefined },
  { key: "new-workspace", label: "Move to new workspace", icon: "workspace.new", onSelect: () => undefined },
  { key: "new-window", label: "Open in new window", icon: "app.open.external", onSelect: () => undefined },
  "separator",
  { key: "archive", label: "Archive", icon: "inbox", onSelect: () => undefined },
  // The tab-owned close action stays the last row, like Chrome's tab actions.
  { key: "close", label: "Close", icon: "tab.close", shortcutAction: "closeTab", onSelect: () => undefined },
];

// The summary's panel toggle as the App passes it (summary/SummaryButton.tsx).
const panelToggle = (shown: boolean, icon = "view.list.short") =>
  createElement(PanelToggle, {
    className: "acpmux-summary-button",
    label: "Chat summary",
    shown,
    icon,
    onToggle: () => undefined,
  });
const summary = panelToggle(false);
const sessionInfoToggle = createElement(PanelToggle, {
  className: "acpmux-session-info-toggle",
  label: "Session Info",
  shown: true,
  onToggle: () => undefined,
});

const openMenu: Play = async (ctx) => {
  await ctx.focus({ role: "button", name: "Chat actions" });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]'));
};

// The App reports Terminal's, Browser's (a plain browser and the chat's page, both Browser's to close),
// and Changes' panels open and panes beside the chat (its headerState push).
const panelsOpen: Play = async (ctx) => {
  const { setHeaderState } = await import("./headerState");
  setHeaderState({ lit: ["splitRight", "splitBrowserRight", "openDiffViewer", "preview"], sideTabs: true });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-header-tool[aria-pressed="true"]'));
};

// Claude Code desktop's top strip (Leo 2026-10-21): no separators, the right-side panel's toggle
// first, every button a 24px square on one 26px pitch, every glyph the same size. The chat menu's ⋯ is
// one of them: the horizontal ellipsis in the same square (Leo 2026-11-04: "i guess we ought to just make
// this a horizontal ellipsis?" and "at least give our button square padding. so all those things are
// proportional").
const squareTools =
  (size: number, gap: number): Play =>
  async (ctx) => {
    const buttons = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-header-tools button")];
    if (buttons.length < 2) throw new Error("the header must show its tools");
    for (const button of buttons) {
      const box = button.getBoundingClientRect();
      if (Math.round(box.width) !== size || Math.round(box.height) !== size)
        throw new Error(
          `header button ${button.getAttribute("aria-label")} is ${box.width}x${box.height}, not a ${size}px square`,
        );
      const glyph = button.querySelector("[data-icon]")?.getBoundingClientRect();
      if (!glyph) throw new Error(`header button ${button.getAttribute("aria-label")} draws no glyph`);
      const pads = [glyph.left - box.left, box.right - glyph.right, glyph.top - box.top, box.bottom - glyph.bottom];
      if (Math.max(...pads) - Math.min(...pads) > 0.5)
        throw new Error(
          `header button ${button.getAttribute("aria-label")} pads its glyph unevenly: ${pads.join(", ")}`,
        );
    }
    const lefts = buttons.map((button) => button.getBoundingClientRect().left);
    if (lefts.slice(1).some((left, index) => Math.round(left - lefts[index]!) !== size + gap))
      throw new Error(`header buttons are not on one ${size + gap}px pitch`);
    const more = ctx.find({ role: "button", name: "Chat actions" });
    if (more.querySelector("[data-icon]")?.getAttribute("data-icon") !== "action.more")
      throw new Error("the chat menu's trigger must draw the horizontal ellipsis (action.more)");
  };

const groupedControls: Play = async (ctx) => {
  const first = ctx.document.querySelector(".acpmux-header-tools button");
  if (!first?.classList.contains("acpmux-summary-button"))
    throw new Error("the panel toggle must be the first of the header's icons");
  if (ctx.document.querySelector(".acpmux-header-tools hr, .acpmux-header-separator"))
    throw new Error("the header tools draw a separator");
  await squareTools(24, 2)(ctx);
  const buttons = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-header-tools button")];
  const glyphs = new Set(buttons.map((button) => button.querySelector("[data-icon]")?.getBoundingClientRect().width));
  if (glyphs.size !== 1) throw new Error(`header glyphs come in several sizes: ${[...glyphs].join(", ")}`);
};

// Three complete treatments, kept in the gallery. Only the compact treatment ships; alternatives
// change fixture geometry rather than adding another product preference or toolbar row.
const groupTreatment =
  (size: number, gap: number): Play =>
  async (ctx) => {
    const tools = ctx.document.querySelector<HTMLElement>(".acpmux-header-tools")!;
    if (ctx.document.defaultView!.getComputedStyle(tools).gap !== `${gap}px`)
      throw new Error("the group must render at its selected spacing");
    for (const button of tools.querySelectorAll<HTMLElement>(".acpmux-header-tool")) {
      const box = button.getBoundingClientRect();
      if (box.width !== size || box.height !== size) throw new Error("the buttons must render at their selected size");
    }
    await ctx.hover({ role: "button", name: "Terminal" });
  };

// Plain icons (Leo 2026-10-25: "why do the icons have their own background border situation instead of
// just being, you know, good"; 2026-10-31: "AND THE FUCKING BACKGROUND ON THIS FUCKING BUILD ON THESE
// BUTTONS STILL ISN'T FUCKING REMOVESD"): with the right-side panel and Terminal's split open, Terminal
// hovered and the chat menu open, no header tool draws a border or a shadow, and none at rest draws a fill.
// A pressed one reads as on by the filled rounded square and its lit ink, hovered or not, and the open
// menu's trigger keeps the square too (Leo, 2026-10-26: "why is the button not toggled?"; 2026-11-02:
// "HAVE THE ... TOGGLED HIGHLIGHT", his reference; #28962 removed only the resting fill).
const plainIcons: Play = async (ctx) => {
  const { setHeaderState } = await import("./headerState");
  setHeaderState({ lit: ["splitRight"] });
  await ctx.waitFor(() => ctx.document.querySelector('[data-quick-action="terminal"][aria-pressed="true"]'));
  await ctx.hover({ role: "button", name: "Chat summary" });
  const panel = ctx.find({ selector: '.acpmux-summary-button[aria-pressed="true"]' });
  const view = ctx.document.defaultView!;
  const tools = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-header-tools .acpmux-header-tool")];
  const clear = (color: string) => /^rgba\(.*,\s*0\)$|^transparent$/.test(color);
  if (clear(view.getComputedStyle(panel).backgroundColor))
    throw new Error("the open panel toggle loses its filled square on hover");
  const litInk = view.getComputedStyle(panel).color;
  await ctx.hover({ role: "button", name: "Terminal" });
  await openMenu(ctx);
  await ctx.hover({ role: "menuitem", name: "Rename" });
  const menuButton = ctx.find({ role: "button", name: "Chat actions" });
  if (!menuButton.hasAttribute("data-popup-open")) throw new Error("the chat menu closed on pointer exit");
  // The open menu's trigger takes the text's ink, unlike a tool at rest (Browser is not pressed here).
  const restInk = view.getComputedStyle(ctx.find({ selector: '[data-quick-action="browser"]' })).color;
  await ctx.waitFor(() => view.getComputedStyle(menuButton).color !== restInk);
  for (const tool of tools) {
    const style = view.getComputedStyle(tool);
    const name = tool.getAttribute("aria-label");
    const pressed = tool.getAttribute("aria-pressed") === "true";
    const lit = pressed || tool.hasAttribute("data-popup-open") || tool.matches(":hover");
    if (lit && pressed && clear(style.backgroundColor))
      throw new Error(`header tool ${name} is pressed without its square`);
    if (!lit && !clear(style.backgroundColor))
      throw new Error(`header tool ${name} draws a fill at rest: ${style.backgroundColor}`);
    if (pressed && style.color !== litInk) throw new Error(`header tool ${name} is pressed without the lit ink`);
    if (["top", "right", "bottom", "left"].some((side) => style.getPropertyValue(`border-${side}-width`) !== "0px"))
      throw new Error(`header tool ${name} draws a border`);
    if (style.boxShadow !== "none") throw new Error(`header tool ${name} draws a shadow: ${style.boxShadow}`);
  }
  const on = ctx.find({ selector: '.acpmux-summary-button[aria-pressed="true"]' });
  const off = ctx.find({ selector: '[data-quick-action="browser"]' });
  if (view.getComputedStyle(on).color === view.getComputedStyle(off).color)
    throw new Error("the open panel's toggle has the same ink as a tool at rest");
};

// Session Info open: its toggle is the filled rounded square with the lit ink, and every other tool
// has nothing behind it at rest (Leo 2026-11-02: "HAVE THE ... TOGGLED HIGHLIGHT", settled by his
// reference of the header with its list button highlighted; #28962 removed only the resting fill).
// `accentless` applies a dark theme with no accent first (the default neutral accent: the lit ink is the
// primary text), where an ink-only toggle read as off.
const sessionInfoOpen =
  (accentless: boolean): Play =>
  async (ctx) => {
    if (accentless) {
      const [{ applyAgentTheme }, { agentPaneTheme }, tokens] = await Promise.all([
        import("../../shared/theme"),
        import("../../../gallery/theme/web"),
        import("../../../gallery/theme/tokens"),
      ]);
      const dark = tokens.deriveTokens({ ...tokens.GHOSTTY_DEFAULT, accent: "neutral" });
      if (!dark.isDark) throw new Error("the fixture theme is not dark");
      applyAgentTheme(agentPaneTheme(dark, false) as never);
    }
    await ctx.waitFor(() => ctx.document.querySelector('.acpmux-session-info-toggle[aria-pressed="true"]'));
    const view = ctx.document.defaultView!;
    const clear = (color: string) => /^rgba\(.*,\s*0\)$|^transparent$/.test(color);
    const toggle = ctx.find({ selector: '.acpmux-session-info-toggle[aria-pressed="true"]' });
    const style = view.getComputedStyle(toggle);
    if (clear(style.backgroundColor)) throw new Error("the open Session Info toggle draws no filled square");
    // The lit ink as the page resolves it (header.css's fallbacks), read from a probe.
    const probe = ctx.document.createElement("span");
    probe.style.color = "var(--agent-lit-glyph, var(--agent-accent, var(--agent-text)))";
    toggle.parentElement!.append(probe);
    const litInk = view.getComputedStyle(probe).color;
    probe.remove();
    // The tool's ink eases over its 80ms colour transition (header.css), so right after the theme
    // changes it can still read the old theme's ink: wait for it to settle before judging it.
    try {
      await ctx.waitFor(() => view.getComputedStyle(toggle).color === litInk, { capMs: 1000 });
    } catch {
      throw new Error(`the open Session Info toggle is not lit: ${style.color} vs ${litInk}`);
    }
    for (const tool of ctx.document.querySelectorAll<HTMLElement>(".acpmux-header-tools .acpmux-header-tool")) {
      if (tool === toggle || tool.matches(":hover, [data-popup-open], [aria-pressed=true]")) continue;
      const fill = view.getComputedStyle(tool).backgroundColor;
      if (!clear(fill)) throw new Error(`header tool ${tool.getAttribute("aria-label")} draws a fill at rest: ${fill}`);
    }
  };

// The App found the chat branch's pull request: open, 3 of 5 checks passed, one failing (cx-tcwj).
const pullRequestChip: Play = async (ctx) => {
  const { setHeaderState } = await import("./headerState");
  setHeaderState({
    pullRequest: {
      url: "https://github.com/manaflow-ai/cmux/pull/19375",
      number: 19375,
      state: "open",
      checks: { state: "failing", passed: 3, total: 5 },
    },
  });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-header-pr"));
};

// A worktree chat (cx-lyqio.3b): its branch shows once `git.status` answers, beside the PR chip.
const worktreePill: Play = async (ctx) => {
  await pullRequestChip(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-header-worktree"));
};

// The pill's popover after Apply (cx-lyqio.4): the chat's work landed in the main checkout.
const worktreeApplied: Play = async (ctx) => {
  await worktreePill(ctx);
  await ctx.click({ selector: ".acpmux-header-worktree" });
  await ctx.click({ role: "button", name: "Apply to main checkout" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-worktree-apply output"));
};

// The pill's popover after Remove (cx-lyqio.5): the worktree holds work found nowhere else, so it
// stays, and only "Remove anyway" would discard it.
const worktreeRemoveRefused: Play = async (ctx) => {
  await worktreePill(ctx);
  await ctx.click({ selector: ".acpmux-header-worktree" });
  await ctx.click({ role: "button", name: "Remove worktree" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-worktree-remove [role=alert]"));
};

// The chip mounts on React's next render, not inside setHeaderState; let that render paint first so
// its row shift is not counted against the click.
async function chipShown(ctx: PlayContext) {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-header-pr"));
  const view = ctx.document.defaultView!;
  await new Promise((done) => view.requestAnimationFrame(() => view.requestAnimationFrame(done)));
}

// A click on the chip opens its status: title, state and review, then each check, failing first
// (cx-ncc.77.1).
const pullRequestStatus: Play = async (ctx) => {
  const { setHeaderState } = await import("./headerState");
  setHeaderState({
    pullRequest: {
      url: "https://github.com/manaflow-ai/cmux/pull/19560",
      number: 19560,
      title: "cx-ncc.74: stage and unstage single hunks in the Changes view",
      state: "open",
      review: "changes_requested",
      mergeable: "mergeable",
      checks: { state: "failing", passed: 3, total: 5 },
      checkList: [
        { name: "web / react-apps-check", state: "failed", url: "https://github.com/manaflow-ai/cmux/actions/runs/1" },
        {
          name: "macOS / Release compile",
          state: "pending",
          url: "https://github.com/manaflow-ai/cmux/actions/runs/2",
        },
        { name: "web / typecheck", state: "passed", url: "https://github.com/manaflow-ai/cmux/actions/runs/3" },
        { name: "cmux-tui / focused", state: "passed", url: "https://github.com/manaflow-ai/cmux/actions/runs/4" },
        { name: "CLA", state: "passed" },
      ],
    },
  });
  await chipShown(ctx);
  await ctx.click({ selector: ".acpmux-header-pr" });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-pr-check").length === 5);
};

// A green pull request's status offers Merge; Merge asks in place before it merges (cx-ncc.77.4).
const pullRequestMerge: Play = async (ctx) => {
  const { setHeaderState } = await import("./headerState");
  setHeaderState({
    pullRequest: {
      url: "https://github.com/manaflow-ai/cmux/pull/19605",
      number: 19605,
      title: "cx-ncc.77.3: Address sends a review comment to the chat",
      state: "open",
      review: "approved",
      mergeable: "mergeable",
      checks: { state: "passing", passed: 3, total: 3 },
      checkList: [
        { name: "web / react-apps-check", state: "passed" },
        { name: "macOS / Release compile", state: "passed" },
        { name: "CLA", state: "passed" },
      ],
    },
  });
  await chipShown(ctx);
  await ctx.click({ selector: ".acpmux-header-pr" });
  await ctx.click({ role: "button", name: "Merge" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Confirm merge" }));
};

// Right-click Browser: the menu to move it, pick toggle or open, and show or hide each button (#19156).
const customizeMenu: Play = async (ctx) => {
  const button = ctx.find({ selector: '[data-quick-action="browser"]' });
  const box = button.getBoundingClientRect();
  const view = ctx.document.defaultView!;
  button.dispatchEvent(
    new view.MouseEvent("contextmenu", {
      bubbles: true,
      cancelable: true,
      clientX: box.left + box.width / 2,
      clientY: box.top + box.height / 2,
    }),
  );
  await ctx.waitFor(() =>
    ctx.document.querySelector('[role="menu"] [role="menuitemcheckbox"], [role="menu"] [role="menuitem"]'),
  );
};

const keyboardMenu: Play = async (ctx) => {
  await openMenu(ctx);
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => ctx.document.querySelector('[role="menuitem"][data-highlighted]'));
  await ctx.press("Escape");
  await ctx.waitFor(() => {
    return (
      !ctx.document.querySelector('[role="menu"]') &&
      ctx.document.activeElement?.getAttribute("aria-label") === "Chat actions"
    );
  });
};

// The chat's grants, revocable with default settings: the chat menu's Revoke Granted Access lists
// each one (header/grantsMenu.ts), now that the composer's mode menu lists the modes alone.
const revokeAccessOpen: Play = async (ctx) => {
  await openMenu(ctx);
  await ctx.focus({ role: "menuitem", name: "Revoke Granted Access" });
  await ctx.press("ArrowRight");
  await ctx.waitFor(() => ctx.document.querySelectorAll('[role="menu"]').length === 2);
};

const keyboardSubmenu: Play = async (ctx) => {
  await openMenu(ctx);
  await ctx.focus({ role: "menuitem", name: "Hand off to…" });
  await ctx.press("ArrowRight");
  await ctx.waitFor(() => ctx.document.querySelectorAll('[role="menu"]').length === 2);
  await ctx.press("Escape");
  await ctx.waitFor(() => ctx.document.querySelectorAll('[role="menu"]').length === 1);
  await ctx.press("Escape");
  await ctx.waitFor(() => {
    return (
      !ctx.document.querySelector('[role="menu"]') &&
      ctx.document.activeElement?.getAttribute("aria-label") === "Chat actions"
    );
  });
};

const copySubmenu: Play = async (ctx) => {
  await openMenu(ctx);
  await ctx.focus({ role: "menuitem", name: "Copy" });
  await ctx.press("ArrowRight");
  await ctx.waitFor(() => ctx.document.querySelectorAll('[role="menu"]').length === 2);
};

// A Cloud chat's machine rows (cloudMachineMenu.ts), placed as the App places them: before Archive's group.
const noop = () => undefined;
const noCall = async () => undefined;
const noStop = async () => true;
const noLive = () => ({ session: undefined, running: false });
const galleryT = translate;
const withMachine = (machine: ChatMenuItem[]): ChatMenuItem[] => {
  const rows = menuRows();
  const archive = rows.findIndex((row) => row !== "separator" && row.key === "archive");
  return [...rows.slice(0, archive), ...machine, "separator", ...rows.slice(archive)];
};

const inbox = (
  <NeedsYouButton
    items={[]}
    actions={{ answer: async () => undefined, goTo: () => undefined, ask: async () => undefined }}
  />
);

const base: HeaderToolsProps = {
  onTerminal: () => undefined,
  onSplitDown: () => undefined,
  onBrowser: () => undefined,
  onSideTabs: () => undefined,
  onFiles: () => undefined,
  summary,
  menu: menuRows,
  onMenuOpen: async () => undefined,
};


// Thunderdome B, header icon motion (headerMotion.ts; Debug Settings agentChat.headerMotion; Leo
// 2026-11-05: should the top-right icons be "a little more animated?"). The plays freeze each motion
// at a frame (every running animation paused at `at` ms), so a still shows it mid-flight.
const frozenAt =
  (at: number): Play =>
  async (ctx) => {
    const view = ctx.document.defaultView!;
    await new Promise((done) => view.requestAnimationFrame(() => done(undefined)));
    for (const animation of ctx.document.getAnimations()) {
      animation.pause();
      animation.currentTime = at;
    }
  };
const motionLit =
  (lit: string[], at?: number): Play =>
  async (ctx) => {
    const { setHeaderState } = await import("./headerState");
    setHeaderState({ lit: [] });
    await new Promise((done) => setTimeout(done, 300));
    setHeaderState({ lit });
    await ctx.waitFor(() => ctx.document.querySelector('.acpmux-header-tool[aria-pressed="true"]'));
    if (at !== undefined) await frozenAt(at)(ctx);
  };
const motionArrive =
  (at?: number): Play =>
  async (ctx) => {
    const { setHeaderState } = await import("./headerState");
    setHeaderState({ lit: [] });
    await new Promise((done) => setTimeout(done, 300));
    // Changes shows while its diff is open: it arrives, and Terminal and Browser make room.
    setHeaderState({ lit: ["openDiffViewer"] });
    await ctx.waitFor(() => ctx.document.querySelector('[data-quick-action="changes"]'));
    if (at !== undefined) await frozenAt(at)(ctx);
  };
const motionMorph =
  (at: number): Play =>
  async (ctx) => {
    ctx.find({ selector: '[data-quick-action="terminal"]' }).click();
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-header-morph"));
    await frozenAt(at)(ctx);
  };
const motionHover =
  (name: string): Play =>
  async (ctx) => {
    const button = ctx.find({ role: "button", name });
    button.dispatchEvent(new (ctx.document.defaultView!.PointerEvent)("pointerover", { bubbles: true }));
    button.dispatchEvent(new (ctx.document.defaultView!.PointerEvent)("pointerenter", { bubbles: false }));
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-header-preview"), { capMs: 2000 });
  };
const motionBase = (motion: HeaderToolsProps["motion"]): HeaderToolsProps => ({
  ...base,
  motion,
  summary: panelToggle(false),
  hasChanges: true,
  onChanges: () => undefined,
  previewUrl: "http://localhost:5173/",
  onPreview: () => undefined,
});
const motionVariants = {
  "motion-still": {
    note: "Header motion: still (the shipped default). Nothing moves; the pressed square appears at once.",
    props: { ...motionBase("still"), working: true },
    play: motionLit(["splitRight"]),
  },
  "motion-cue-working": {
    note: "Header motion: cue. While the chat's turn runs, a crisp 5px dot on Changes breathes (1.2 s, opacity only, the only loop, and only while a turn runs).",
    props: { ...motionBase("animated-cue"), working: true },
  },
  "motion-cue-pending": {
    note: "Header motion: cue. The turn is over and its changes wait: the dot holds still. No work, no dot.",
    props: motionBase("animated-cue"),
  },
  "motion-cue-plate-60ms": {
    note: "Header motion: cue. Terminal's split just opened: 60 ms in, its pressed plate is growing out of the glyph on the one spring (240 ms).",
    props: motionBase("animated-cue"),
    play: motionLit(["splitRight"], 60),
  },
  "motion-cue-plate-settled": {
    note: "Header motion: cue. The plate settled: the same filled rounded square the shipped header draws.",
    props: motionBase("animated-cue"),
    play: motionLit(["splitRight"]),
  },
  "motion-spring-arrive-50ms": {
    note: "Header motion: spring. Changes became relevant: 50 ms in, it springs up from a dot while Terminal and Browser glide right to make room (transforms only).",
    props: { ...motionBase("animated-spring"), hasChanges: false },
    play: motionArrive(50),
  },
  "motion-spring-arrive-120ms": {
    note: "Header motion: spring. 120 ms in: Changes overshoots a touch, its neighbours nearly there.",
    props: { ...motionBase("animated-spring"), hasChanges: false },
    play: motionArrive(120),
  },
  "motion-spring-arrive-settled": {
    note: "Header motion: spring. Settled: the same row the shipped header draws, Changes lit while its diff is open.",
    props: { ...motionBase("animated-spring"), hasChanges: false },
    play: motionArrive(),
  },
  "motion-morph-fly-90ms": {
    note: "Header motion: morph. A click on Terminal opens its split: 90 ms in, the glyph leaves for the pane's right edge, widening into a tab.",
    props: motionBase("animated-morph"),
    play: motionMorph(90),
  },
  "motion-morph-fly-170ms": {
    note: "Header motion: morph. 170 ms in: the glyph has become the Terminal tab where the split lands, then fades as the real pane shows.",
    props: motionBase("animated-morph"),
    play: motionMorph(170),
  },
  "motion-morph-hover-browser": {
    note: "Header motion: morph. Resting on Browser previews what a click opens: the chat's page in the right column, with its address. It stands in for the tooltip.",
    props: motionBase("animated-morph"),
    play: motionHover("Browser"),
  },
  "motion-morph-hover-closes": {
    note: "Header motion: morph. Resting on Terminal while its split is open: the panel draws dashed, the click closes it.",
    props: motionBase("animated-morph"),
    play: async (ctx) => {
      await motionLit(["splitRight"])(ctx);
      await motionHover("Terminal")(ctx);
    },
  },
} satisfies Record<string, { note: string; props: HeaderToolsProps; play?: Play }>;

export default componentEntry<HeaderToolsProps>({
  id: "agent-pane.header-tools",
  title: "Chat header tools",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 390, normal: 560, wide: 860 },
  anchors: [{ selector: ".acpmux-header-tools" }],
  covers: [
    "agent-session/acpmux/header/ChatHeaderTools.tsx#ChatHeaderTools",
    "agent-session/acpmux/header/HeaderIcon.tsx#HeaderIcon",
    "agent-session/acpmux/header/PullRequestChip.tsx#PullRequestChip",
    "agent-session/acpmux/header/PullRequestMerge.tsx#PullRequestMerge",
    "agent-session/acpmux/header/WorktreePill.tsx#WorktreePill",
    "agent-session/acpmux/header/WorktreeApply.tsx#WorktreeApply",
    "agent-session/acpmux/header/WorktreeRemove.tsx#WorktreeRemove",
    "agent-session/acpmux/header/PanelToggle.tsx#PanelToggle",
    "agent-session/acpmux/header/HeaderToolPreview.tsx#HeaderToolPreview",
  ],
  load: () =>
    import("./ChatHeaderTools").then(
      (module) =>
        ({ treatment, ...props }: HeaderToolsProps) =>
          createElement(
            Fragment,
            null,
            treatment
              ? createElement(
                  "style",
                  null,
                  `.acpmux-header-tools{--acpmux-header-tool-size:${treatment.size};--acpmux-header-tool-gap:${treatment.gap}}`,
                )
              : null,
            createElement(module.ChatHeaderTools, props),
          ),
    ),
  // The pane's own stylesheets, as the app ships them (build-agent-pane-web.sh): its theme variables,
  // the shared popup surface, then the header's rules. With header.css alone every popup was
  // see-through in the gallery and the "Hand off to…" submenu bug did not show as it does in the app.
  styles: () => Promise.all([import("../styles.css"), import("../../../ui/popupSurface.css"), import("./header.css")]),
  checks: {
    popupLayer: {
      value: true,
      reason: "The chat menu and its Hand off to… submenu must each be the top, unclipped, opaque layer.",
    },
    anchorMovePx: {
      value: 0,
      reason: "Opening the chat menu uses a portal and must not move the header tool row.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Header menu keyboard transitions should stay responsive on the gallery host.",
    },
  },
  variants: {
    ...motionVariants,
    "native-row-off": {
      note: "The default web toolbar: Summary, Needs You, quick actions and the chat menu remain web controls.",
      props: { ...base, inbox },
    },
    "native-row-tools": {
      note: "Native row tools opt-in: Summary, quick-action icons, their customization menus and chat overflow move to the native host. Needs You keeps its web button and anchored rich list. No default changes.",
      props: {
        ...base,
        inbox,
        nativeRowTools: {
          enabled: true,
          callNative: async () => undefined,
          panel: { id: "summary", label: "Summary", toggled: false, run: () => undefined },
        },
      },
      play: async (ctx) => {
        await ctx.waitFor(() => !ctx.document.querySelector("[data-quick-action], .acpmux-header-panel-toggle"));
        ctx.find({ selector: ".acpmux-needs-you-button" });
        if (ctx.document.querySelector('button[aria-label="Chat actions"]'))
          throw new Error("native chat overflow must not leave a duplicate DOM trigger");
      },
    },
    "unified-compact": {
      note: "Chosen: one 24px target on a 26px pitch, 16px SF Symbols in the app, overflow last. The selected panel glyph uses accent ink; only the hovered button changes its hover ink. Fits the shared 28px tab row.",
      props: {
        ...base,
        hasChanges: true,
        onChanges: () => undefined,
        summary: panelToggle(true),
        treatment: { size: "var(--grid-pill)", gap: "var(--grid-half-step)" },
      },
      play: groupTreatment(24, 2),
    },
    "unified-roomy": {
      note: "Alternative: 28px targets on a 32px pitch. Easier to acquire, but consumes more tab-strip room and pushes narrow panes into a separate header sooner.",
      props: {
        ...base,
        hasChanges: true,
        onChanges: () => undefined,
        summary: panelToggle(true),
        treatment: { size: "28px", gap: "4px" },
      },
      play: groupTreatment(28, 4),
    },
    "unified-tight": {
      note: "Alternative: 24px targets without gaps. Saves width, but leaves less separation for adjacent terminal and browser actions.",
      props: {
        ...base,
        hasChanges: true,
        onChanges: () => undefined,
        summary: panelToggle(true),
        treatment: { size: "24px", gap: "0px" },
      },
      play: groupTreatment(24, 0),
    },
    "density-compact": {
      note: "Compact density (shipped): every tool, the ⋯ included, is the layout grid's compact highlight square (--grid-pill, 24px) with its 16px glyph centred and equal padding on every side, on an even --grid-half-step gap; the hover pill is that square with the controls' radius.",
      props: {
        ...base,
        hasChanges: true,
        onChanges: () => undefined,
        summary: panelToggle(false),
        treatment: { size: "var(--grid-pill)", gap: "var(--grid-half-step)" },
      },
      play: async (ctx) => {
        await squareTools(24, 2)(ctx);
        await ctx.hover({ role: "button", name: "Chat actions" });
      },
    },
    "density-comfortable": {
      note: "Comfortable density: the same squares at the grid's comfortable highlight (--grid-pill-comfortable, 28px) on a --grid-base gap, the glyph still centred with equal padding.",
      props: {
        ...base,
        hasChanges: true,
        onChanges: () => undefined,
        summary: panelToggle(false),
        treatment: { size: "var(--grid-pill-comfortable)", gap: "var(--grid-base)" },
      },
      play: async (ctx) => {
        await squareTools(28, 4)(ctx);
        await ctx.hover({ role: "button", name: "Chat actions" });
      },
    },
    "more-horizontal": {
      note: "The chat menu's trigger is the app's horizontal ellipsis (action.more, SF Symbol ellipsis) in the same square as every tool, hovered (Leo 2026-11-04: \"i guess we ought to just make this a horizontal ellipsis?\").",
      props: { ...base, summary: panelToggle(false) },
      play: async (ctx) => {
        await squareTools(24, 2)(ctx);
        await ctx.hover({ role: "button", name: "Chat actions" });
      },
    },
    idle: {
      note: "The complete tab header: Terminal, Browser, summary, and chat actions (New tab, Files and Split Down are in it).",
      props: base,
    },
    "panels-open": {
      note: "Changes, Terminal and Browser are lit while their panels are open beside the chat (cx-00n1); Browser holds the chat's page; Hide tabs is in the chat menu.",
      props: {
        ...base,
        sideTabs: true,
        hasChanges: true,
        onChanges: () => undefined,
        previewUrl: "http://localhost:5173/",
        onPreview: () => undefined,
      },
      play: panelsOpen,
    },
    "panel-open": {
      note: "Session Info is open: its toggle is the filled rounded square with the lit ink and selected glyph; the other header controls have nothing behind them.",
      props: { ...base, summary: panelToggle(true) },
    },
    "session-info-open": {
      note: "Session Info open: its toggle is the filled rounded square (the hover pill's size, a subtle tint) with the lit ink; every other tool has nothing behind it at rest.",
      props: { ...base, summary: sessionInfoToggle },
      play: sessionInfoOpen(false),
    },
    "session-info-open-accentless": {
      note: "The same in a dark theme with no accent (the lit ink is the primary text): the filled square still shows the toggle on.",
      props: { ...base, summary: sessionInfoToggle },
      play: sessionInfoOpen(true),
    },
    "panel-icon-list": {
      note: 'Panel icon option: two list rows with circular markers, centred on the icon grid; this is the shipped choice (Leo 2026-11-04: "make our session info button 2 rows too").',
      props: { ...base, summary: panelToggle(false, "view.list.short") },
    },
    "panel-icon-list-three": {
      note: "Panel icon option: the earlier three-row list (view.list), shown for comparison.",
      props: { ...base, summary: panelToggle(false, "view.list") },
    },
    "panel-icon-info": {
      note: "Panel icon option: the compact information glyph, shown for comparison with the list control.",
      props: { ...base, summary: panelToggle(false, "status.info") },
    },
    "panel-icon-session": {
      note: "Panel icon option: the session speech-bubble glyph, shown for comparison with the list control.",
      props: { ...base, summary: panelToggle(false, "agent.session") },
    },
    "plain-icons": {
      note: "Plain icons: the panel and Terminal's split open, Terminal hovered, the chat menu open; no tool at rest draws a box, and the open panel's toggle is the filled rounded square with the lit ink.",
      props: { ...base, summary: panelToggle(true) },
      play: plainIcons,
    },
    "browser-preview": {
      note: "The chat's last turn named a local page: Browser opens it beside the chat and its tooltip names it; there is no separate Preview button.",
      props: { ...base, previewUrl: "http://localhost:5173/", onPreview: () => undefined },
    },
    "grouped-controls": {
      note: "Claude Code desktop's strip: the panel toggle first, no separators, 24px square buttons on one 26px pitch, one glyph size.",
      props: base,
      play: groupedControls,
    },
    "pull-request": {
      note: "The chat branch's pull request leads the tools: its number, its state and how its checks stand (cx-tcwj).",
      props: { ...base, hasChanges: true, onChanges: () => undefined },
      play: pullRequestChip,
    },
    "pull-request-status": {
      note: "A click on the PR chip lists its title, state, review and each check, failing first (cx-ncc.77.1).",
      props: { ...base, hasChanges: true, onChanges: () => undefined },
      play: pullRequestStatus,
    },
    "pull-request-merge": {
      note: "A green pull request's status offers Merge, which asks once more in place before merging (cx-ncc.77.4).",
      props: {
        ...base,
        hasChanges: true,
        onChanges: () => undefined,
        onMergePullRequest: async () => ({ queued: false }),
      },
      play: pullRequestMerge,
    },
    worktree: {
      note: "A chat started in a worktree names its branch beside the PR chip; the tooltip names the main checkout and the base (cx-lyqio.3b).",
      props: {
        ...base,
        hasChanges: true,
        onChanges: () => undefined,
        folder: "/Users/me/.cmux/worktrees/cmux/fix-login",
        readStatus: async () => ({
          branch: "cmux/fix-login",
          base: "main",
          detached: false,
          worktree: { main_root: "/Users/me/Projects/cmux" },
        }),
      },
      play: worktreePill,
    },
    "worktree-apply": {
      note: "A click on the worktree pill opens it with Apply, which brought the chat's work to the main checkout (cx-lyqio.4).",
      props: {
        ...base,
        hasChanges: true,
        onChanges: () => undefined,
        folder: "/Users/me/.cmux/worktrees/cmux/fix-login",
        onApplyWorktree: async () => ({
          value: { main_root: "/Users/me/Projects/cmux", files: ["a.ts", "b.ts", "c.ts"] },
        }),
        readStatus: async () => ({
          branch: "cmux/fix-login",
          base: "main",
          detached: false,
          worktree: { main_root: "/Users/me/Projects/cmux" },
        }),
      },
      play: worktreeApplied,
    },
    "worktree-remove": {
      note: "Remove keeps a worktree with uncommitted work and says so inline; only Remove anyway discards it (cx-lyqio.5).",
      props: {
        ...base,
        hasChanges: true,
        onChanges: () => undefined,
        folder: "/Users/me/.cmux/worktrees/cmux/fix-login",
        onApplyWorktree: async () => ({ value: { main_root: "/Users/me/Projects/cmux", files: [] } }),
        onRemoveWorktree: async () => {
          throw Object.assign(new Error("refused"), {
            code: "operation.failed",
            details: { reason: "uncommitted_changes", extra: { files: ["src/login.ts", "notes.md"], count: 2 } },
          });
        },
        readStatus: async () => ({
          branch: "cmux/fix-login",
          base: "main",
          detached: false,
          worktree: { main_root: "/Users/me/Projects/cmux" },
        }),
      },
      play: worktreeRemoveRefused,
    },
    "customize-menu": {
      note: "Right-clicking a quick action moves it, picks toggle or open, and shows or hides each button (cx-00n1).",
      props: {
        ...base,
        hasChanges: true,
        onChanges: () => undefined,
        previewUrl: "http://localhost:5173/",
        onPreview: () => undefined,
        onCustomize: () => undefined,
      },
      play: customizeMenu,
    },
    "menu-open": {
      note: "The chat menu starts with the quick actions not shown as buttons (New tab, Files, Split Down), then the tab's own rows, ending with Close.",
      props: base,
      play: openMenu,
    },
    "menu-avatar": {
      height: 860,
      note: "A chat with an agent session and an uploaded avatar: Set Avatar… and Remove Avatar end the chat menu's tab rows, before Archive and Close (header/avatarRow.ts).",
      props: {
        ...base,
        menu: () => {
          const rows = menuRows();
          const archive = rows.findIndex((row) => row !== "separator" && row.key === "archive");
          const avatar = avatarRows(
            { sessionId: "session-1", hasAvatar: true },
            { set: () => undefined, remove: () => undefined },
          );
          return [...rows.slice(0, archive), ...avatar, "separator", ...rows.slice(archive)];
        },
      },
      play: openMenu,
    },
    "menu-revoke-access": {
      height: 860,
      note: "A chat whose folder is trusted and that allows a command for the chat: Revoke Granted Access ends the tools rows and lists each grant; a pick revokes it. Grants live here, in every chat with default settings, not in the composer's mode menu (Leo, 2026-10-29).",
      props: {
        ...base,
        menu: () => {
          const rows = menuRows();
          const archive = rows.findIndex((row) => row !== "separator" && row.key === "archive");
          const revoke = revokeAccessRows([
            { id: "folder-trust", label: "Trusted atlas", onRemove: noop },
            { id: "chat-permission", label: "Allow for this chat", onRemove: noop },
          ]);
          return [...rows.slice(0, archive), ...revoke, "separator", ...rows.slice(archive)];
        },
      },
      play: revokeAccessOpen,
    },
    "menu-cloud-machine-running": {
      height: 860,
      note: "A chat on a running Cloud machine (Labs > Preview features): Pause Machine sits before the tools rows (cloudMachineMenu.ts).",
      props: {
        ...base,
        menu: () =>
          withMachine(
            cloudMachineRows(
              { id: "vm_1", name: "dev-vm-2", stage: "ready" },
              false,
              galleryT,
              noCall,
              noop,
              noLive,
              noStop,
            ),
          ),
      },
      play: openMenu,
    },
    "menu-cloud-machine-working": {
      height: 860,
      note: "The same while its turn runs: the row says it stops the turn first.",
      props: {
        ...base,
        menu: () =>
          withMachine(
            cloudMachineRows(
              { id: "vm_1", name: "dev-vm-2", stage: "ready" },
              true,
              galleryT,
              noCall,
              noop,
              noLive,
              noStop,
            ),
          ),
      },
      play: openMenu,
    },
    "menu-cloud-machine-paused": {
      height: 860,
      note: "A chat on a paused Cloud machine: Resume Machine.",
      props: {
        ...base,
        menu: () =>
          withMachine(
            cloudMachineRows(
              { id: "vm_1", name: "dev-vm-2", stage: "paused" },
              false,
              galleryT,
              noCall,
              noop,
              noLive,
              noStop,
            ),
          ),
      },
      play: openMenu,
    },
    "keyboard-menu": {
      note: "Enter opens the menu, ArrowDown highlights a row, and Escape returns focus to Chat actions.",
      props: base,
      play: keyboardMenu,
    },
    "keyboard-submenu": {
      note: "Hand off to… opens with ArrowRight; Escape closes the submenu and then the parent menu.",
      props: base,
      play: keyboardSubmenu,
    },
    "menu-copy-submenu": {
      height: 860,
      note: "Copy opens with ArrowRight: Copy as Markdown puts the whole chat on the clipboard, and Save as Markdown… writes the same Markdown to a file the person picks.",
      props: base,
      play: copySubmenu,
    },
    "quick-chat": {
      note: "Quick Chat has no tab to split, so only the summary and chat actions remain.",
      props: { ...base, tabTools: false },
    },
  },
});
