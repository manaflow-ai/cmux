// l10n-allow-file: gallery fixtures (sample chat actions), not shipped UI.
import { createElement } from "react";
import type { ReactNode } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play, PlayContext } from "../../../gallery/play";
import { avatarRows } from "./avatarRow";
import type { ChatMenuItem } from "./ChatHeaderTools";
import { PanelToggle } from "./PanelToggle";
import type { QuickAction } from "./quickActions";

type HeaderToolsProps = {
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
  menu: () => ChatMenuItem[];
  onMenuOpen?: () => Promise<unknown>;
  onMergePullRequest?: (pullRequest: { number: number; url: string }) => Promise<{ queued: boolean }>;
  expand?: string;
  onExpanded?: () => void;
  folder?: string;
  readStatus?: () => Promise<unknown>;
  onApplyWorktree?: (key: string) => Promise<unknown>;
  onRemoveWorktree?: (key: string, discard: boolean) => Promise<unknown>;
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
  {
    key: "continue",
    label: "Continue in",
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
const panelToggle = (shown: boolean, icon = "view.list") =>
  createElement(PanelToggle, {
    className: "acpmux-summary-button",
    label: "Chat summary",
    shown,
    icon,
    onToggle: () => undefined,
  });
const summary = panelToggle(false);

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
// first, every button a 24px square on one 26px pitch, every glyph the same size.
const groupedControls: Play = async (ctx) => {
  const first = ctx.document.querySelector(".acpmux-header-tools button");
  if (!first?.classList.contains("acpmux-summary-button"))
    throw new Error("the panel toggle must be the first of the header's icons");
  if (ctx.document.querySelector(".acpmux-header-tools hr, .acpmux-header-separator"))
    throw new Error("the header tools draw a separator");
  const tools = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-header-tools button")];
  for (const button of tools) {
    const box = button.getBoundingClientRect();
    if (Math.round(box.width) !== 24 || Math.round(box.height) !== 24)
      throw new Error(`header button ${button.getAttribute("aria-label")} is not a 24px square`);
  }
  const lefts = tools.map((button) => button.getBoundingClientRect().left);
  if (lefts.slice(1).some((left, index) => Math.round(left - lefts[index]!) !== 26))
    throw new Error("header buttons are not on one 26px pitch");
  const glyphs = new Set(tools.map((button) => button.querySelector("svg")?.getAttribute("width")));
  if (glyphs.size !== 1) throw new Error(`header glyphs come in several sizes: ${[...glyphs].join(", ")}`);
};

// Plain icons (Leo 2026-10-25: "why do the icons have their own background border situation instead of
// just being, you know, good"): with the right-side panel and Terminal's split open, Terminal hovered
// and the chat menu open, no header tool draws a fill, border or shadow. The open panel's toggle
// reads as on through its ink and selected glyph, including on hover (Leo, 2026-10-27).
const plainIcons: Play = async (ctx) => {
  const { setHeaderState } = await import("./headerState");
  setHeaderState({ lit: ["splitRight"] });
  await ctx.waitFor(() => ctx.document.querySelector('[data-quick-action="terminal"][aria-pressed="true"]'));
  await ctx.hover({ role: "button", name: "Chat summary" });
  const panel = ctx.find({ selector: '.acpmux-summary-button[aria-pressed="true"]' });
  const view = ctx.document.defaultView!;
  const tools = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-header-tools .acpmux-header-tool")];
  const clear = (color: string) => /^rgba\(.*,\s*0\)$|^transparent$/.test(color);
  if (!clear(view.getComputedStyle(panel).backgroundColor))
    throw new Error("the open panel toggle draws a fill on hover");
  await ctx.hover({ role: "button", name: "Terminal" });
  await openMenu(ctx);
  await ctx.hover({ role: "menuitem", name: "Rename" });
  const menuButton = ctx.find({ role: "button", name: "Chat actions" });
  if (!menuButton.hasAttribute("data-popup-open")) throw new Error("the chat menu closed on pointer exit");
  await ctx.waitFor(() => view.getComputedStyle(menuButton).color === view.getComputedStyle(panel).color);
  for (const tool of tools) {
    const style = view.getComputedStyle(tool);
    const name = tool.getAttribute("aria-label");
    if (!clear(style.backgroundColor)) throw new Error(`header tool ${name} draws a fill: ${style.backgroundColor}`);
    if (["top", "right", "bottom", "left"].some((side) => style.getPropertyValue(`border-${side}-width`) !== "0px"))
      throw new Error(`header tool ${name} draws a border`);
    if (style.boxShadow !== "none") throw new Error(`header tool ${name} draws a shadow: ${style.boxShadow}`);
  }
  const on = ctx.find({ selector: '.acpmux-summary-button[aria-pressed="true"]' });
  const off = ctx.find({ selector: '[data-quick-action="browser"]' });
  if (view.getComputedStyle(on).color === view.getComputedStyle(off).color)
    throw new Error("the open panel's toggle has the same ink as a tool at rest");
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

const keyboardSubmenu: Play = async (ctx) => {
  await openMenu(ctx);
  await ctx.focus({ role: "menuitem", name: "Continue in" });
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

export default componentEntry<HeaderToolsProps>({
  id: "agent-pane.header-tools",
  title: "Chat header tools",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 390, normal: 560, wide: 860 },
  anchors: [{ selector: ".acpmux-header-tools" }],
  covers: [
    "agent-session/acpmux/header/ChatHeaderTools.tsx#ChatHeaderTools",
    "agent-session/acpmux/header/PullRequestChip.tsx#PullRequestChip",
    "agent-session/acpmux/header/PullRequestMerge.tsx#PullRequestMerge",
    "agent-session/acpmux/header/WorktreePill.tsx#WorktreePill",
    "agent-session/acpmux/header/WorktreeApply.tsx#WorktreeApply",
    "agent-session/acpmux/header/WorktreeRemove.tsx#WorktreeRemove",
    "agent-session/acpmux/header/PanelToggle.tsx#PanelToggle",
  ],
  load: () => import("./ChatHeaderTools").then((module) => module.ChatHeaderTools),
  // The pane's own stylesheets, as the app ships them (build-agent-pane-web.sh): its theme variables,
  // the shared popup surface, then the header's rules. With header.css alone every popup was
  // see-through in the gallery and the "Continue in" submenu bug did not show as it does in the app.
  styles: () => Promise.all([import("../styles.css"), import("../../../ui/popupSurface.css"), import("./header.css")]),
  checks: {
    popupLayer: {
      value: true,
      reason: "The chat menu and its Continue in submenu must each be the top, unclipped, opaque layer.",
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
      note: "Session Info is open: its toggle uses the text ink and selected glyph without a box, matching every other header control.",
      props: { ...base, summary: panelToggle(true) },
    },
    "panel-icon-list": {
      note: "Panel icon option: three list rows with circular markers, matching ChatGPT's session rail control; this is the shipped choice.",
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
      note: "Plain icons: the panel and Terminal's split open, Terminal hovered, the chat menu open; no tool draws a box, and the open panel's toggle is lit by its ink.",
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
    "keyboard-menu": {
      note: "Enter opens the menu, ArrowDown highlights a row, and Escape returns focus to Chat actions.",
      props: base,
      play: keyboardMenu,
    },
    "keyboard-submenu": {
      note: "Continue in opens with ArrowRight; Escape closes the submenu and then the parent menu.",
      props: base,
      play: keyboardSubmenu,
    },
    "quick-chat": {
      note: "Quick Chat has no tab to split, so only the summary and chat actions remain.",
      props: { ...base, tabTools: false },
    },
  },
});
