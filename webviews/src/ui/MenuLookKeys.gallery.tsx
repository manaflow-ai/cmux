// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
// A theme file's menu and popover look (appearance.menu.*, appearance.popover.*), as the App sends it
// to every page: WebTheme puts MenuLook.webVariables on :root, the --menu-* tokens a look sets
// (ui/README.md, "Menu tokens a look sets") and the plan usage popover's --popover-* tokens. The
// "claude" variants set the tokens Leo's Claude desktop fragment makes (cmux-config
// theme_file::tests CLAUDE_MENU_FRAGMENT; CmuxNextDesignTests MenuLookTests asserts the same
// strings); "standard" sets none, today's look. Leo, 2026-11-19: "i think y'all also ought to emulate
// the things for context menu styling and such maybne in those repos too and the layout and
// proportions as well".
import { useLayoutEffect } from "react";
import { PlanUsageCardBody } from "../agent-session/acpmux/PlanUsageCard";
import type { AcpmuxUsageLimits } from "../agent-session/acpmux/model";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Menu, MenuButton, MenuGroup, MenuItem, MenuPopup, MenuSeparator, Submenu } from "./Menu";

/** The tokens MenuLook.webVariables sends for the Claude desktop fragment. */
const CLAUDE_MENU_TOKENS: Record<string, string> = {
  "--menu-radius": "12px",
  "--menu-border": "color-mix(in srgb, currentColor 10%, transparent)",
  "--menu-fill": "rgba(43, 43, 43, 1.0)",
  "--menu-padding": "8px",
  "--menu-hover-radius": "8px",
  "--menu-row-height": "30px",
  "--menu-shortcut-color": "color-mix(in srgb, currentColor 45%, transparent)",
  "--menu-label-color": "color-mix(in srgb, currentColor 45%, transparent)",
  "--menu-label-weight": "var(--weight-regular, 400)",
  "--menu-separator": "color-mix(in srgb, currentColor 6%, transparent)",
  "--menu-submenu-offset": "8px",
  "--menu-submenu-align-offset": "-8px",
  "--menu-subtitle-color": "color-mix(in srgb, currentColor 45%, transparent)",
  "--popover-padding": "12px",
  "--popover-header-color": "currentColor",
  "--popover-header-size": "var(--text-body, 13px)",
  "--popover-header-weight": "var(--weight-emphasis, 600)",
  "--popover-progress-height": "6px",
};

const NOW = Date.UTC(2026, 10, 4, 3, 0);
const limits: AcpmuxUsageLimits = {
  windows: [
    { id: "session", usedPercent: 22, resetsAt: NOW / 1000 + 5 * 3600 },
    { id: "weekly", usedPercent: 41, resetsAt: NOW / 1000 + 4 * 86_400 },
  ],
};

type Props = { tokens?: Record<string, string> };

function MenuLookKeysGallery({ tokens = {} }: Props) {
  // The App sets these on :root (WebTheme); the gallery does the same for its variant, and puts back
  // what was there when it leaves.
  useLayoutEffect(() => {
    const root = document.documentElement;
    const before = Object.keys(tokens).map((name) => [name, root.style.getPropertyValue(name)] as const);
    for (const [name, value] of Object.entries(tokens)) root.style.setProperty(name, value);
    return () => {
      for (const [name, value] of before) {
        if (value) root.style.setProperty(name, value);
        else root.style.removeProperty(name);
      }
    };
  }, [tokens]);
  return (
    <div className="menu-look-keys-stage">
      <Menu>
        <MenuButton className="menu-look-keys-trigger" label="Open chat menu">
          Chat
        </MenuButton>
        <MenuPopup label="Chat menu">
          <MenuItem shortcut="R">Rename</MenuItem>
          <MenuItem shortcut="P">Pin</MenuItem>
          <Submenu label="Open in">
            <MenuGroup label="Open in">
              <MenuItem shortcut="1">Finder</MenuItem>
              <MenuItem shortcut="2">Terminal</MenuItem>
              <MenuItem shortcut="3">
                <span className="menu-look-keys-two-line">
                  <span>Editor</span>
                  <span className="acpmux-menu-description">Opens the folder in your default editor</span>
                </span>
              </MenuItem>
            </MenuGroup>
          </Submenu>
          <MenuItem disabled>Share</MenuItem>
          <MenuSeparator />
          <MenuItem className="ui-menu-item-destructive" shortcut="⌫">
            Delete
          </MenuItem>
        </MenuPopup>
      </Menu>
      <div className="ui-card ui-glass acpmux-context-card acpmux-plan-pop menu-look-keys-popover">
        <PlanUsageCardBody limits={limits} family="claude" look="claude-bars" now={() => NOW} onOpenUrl={() => {}} />
      </div>
    </div>
  );
}

/** The menu and its submenu open, as in Leo's reference. */
const openSubmenu: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Open chat menu" });
  await ctx.waitFor(() => ctx.find({ role: "menu" }));
  await ctx.focus({ role: "menuitem", name: "Open in" });
  await ctx.press("ArrowRight");
  await ctx.waitFor(() => ctx.document.querySelectorAll('[role="menu"]').length === 2);
};

export default componentEntry<Props>({
  id: "ui.menu-look-keys",
  title: "Menu and popover look from a theme file",
  area: "UI primitives",
  pane: true,
  height: 420,
  widths: { narrow: 560, normal: 720, wide: 900 },
  covers: ["ui/Menu.tsx#Submenu", "agent-session/acpmux/PlanUsageCard.tsx#PlanUsageCardBody"],
  anchors: [{ selector: ".menu-look-keys-trigger" }],
  load: async () => MenuLookKeysGallery,
  styles: () =>
    Promise.all([
      import("./ui.css"),
      import("./popupSurface.css"),
      import("../agent-session/acpmux/styles.css"),
      import("../agent-session/acpmux/contextCard.css"),
      import("../agent-session/acpmux/planUsageCard.css"),
      import("./MenuLookKeys.gallery.css"),
    ]),
  checks: {
    anchorMovePx: { value: 0, reason: "Opening the menu and its submenu must not move the trigger." },
    settleMaxMs: { value: 250, reason: "Menu open and submenu open are local interactions." },
  },
  variants: {
    standard: {
      note: "No appearance.menu.* or appearance.popover.* key set: today's menu, submenu and usage popover.",
      props: {},
      play: openSubmenu,
    },
    claude: {
      note: "Leo's Claude desktop fragment: a #2b2b2b panel with a 12 px corner and a subtle edge, 30 px rows, an 8 px hover corner, muted shortcuts and section label, a thin separator, a flush submenu level with its row, a muted second line; the popover's strong header and 6 px track.",
      props: { tokens: CLAUDE_MENU_TOKENS },
      play: openSubmenu,
    },
    "claude-closed": {
      note: "The same fragment with the menu closed: the usage popover alone.",
      props: { tokens: CLAUDE_MENU_TOKENS },
    },
  },
});
