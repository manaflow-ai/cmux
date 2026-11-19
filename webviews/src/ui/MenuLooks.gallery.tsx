// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
// A session row's menu in four looks (ui/README.md "Menu tokens a look sets"): cmux's own (no
// tokens), and the Claude, Codex and Studio packs' values, set on :root the way a look's
// agent-pane/theme.css sets them. Switching variants swaps the stylesheet in place, as a look's
// hot reload does.
import { useLayoutEffect } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Menu, MenuButton, MenuGroup, MenuItem, MenuPopup, MenuSeparator, Submenu } from "./Menu";

type Look = "cmux" | "claude" | "codex" | "studio";
type Props = { look?: Look };

// Colors are made from the theme's own (look-addons.md), so each reads over a light theme and a dark one.
const text = "var(--agent-text, var(--cmux-text, CanvasText))";
const page = "var(--agent-page-bg, var(--cmux-page-background, Canvas))";
const ink = (percent: number) => `color-mix(in srgb, ${text} ${percent}%, transparent)`;

/** Each pack's tokens: the values its agent-pane/theme.css sets (none for cmux: today's menus). */
export const MENU_LOOKS: Record<Look, Record<string, string>> = {
  cmux: {},
  // Claude desktop's row menu (Leo's screenshots): a solid 12 px panel, 28 pt rows, an 8 px hover
  // inset from the edges, muted single-letter shortcuts, a red Delete, a flush submenu.
  claude: {
    "--menu-radius": "12px",
    "--menu-padding": "8px",
    "--menu-fill": `color-mix(in srgb, ${text} 9%, ${page})`,
    "--menu-border": ink(12),
    "--menu-shadow": "0 8px 24px color-mix(in srgb, black 32%, transparent)",
    "--menu-row-height": "28px",
    "--menu-hover-fill": ink(9),
    "--menu-hover-radius": "8px",
    "--menu-separator": ink(10),
    "--menu-separator-inset": "12px",
    "--menu-label-color": ink(50),
    "--menu-label-weight": "400",
    "--menu-shortcut-color": ink(45),
    "--menu-subtitle-color": ink(50),
    "--menu-destructive": `color-mix(in srgb, var(--agent-danger, #e5534b) 80%, ${text})`,
    "--menu-disabled-opacity": "0.4",
    "--menu-submenu-offset": "8px",
  },
  // Codex desktop's thread menu: frosted glass kept, a 12 px corner, 24 pt rows, separators that
  // start under the labels, a lighter rim and a deeper shadow.
  codex: {
    "--menu-radius": "12px",
    "--menu-padding": "6px",
    "--menu-border": ink(14),
    "--menu-shadow": "0 10px 30px color-mix(in srgb, black 30%, transparent)",
    "--menu-row-height": "24px",
    "--menu-hover-fill": ink(8),
    "--menu-hover-radius": "6px",
    "--menu-separator": ink(12),
    "--menu-separator-inset": "16px",
    "--menu-label-color": ink(45),
    "--menu-shortcut-color": ink(40),
    "--menu-subtitle-color": ink(45),
    "--menu-submenu-offset": "4px",
  },
  // Studio's composer menus: a near-black solid panel, an 8 px corner, a 1 px edge, 28 px rows on a
  // 4 px inset, plain section labels and a quiet second line.
  studio: {
    "--menu-radius": "8px",
    "--menu-padding": "4px",
    "--menu-fill": `color-mix(in srgb, ${text} 3%, ${page})`,
    "--menu-border": ink(12),
    "--menu-shadow": "0 4px 12px color-mix(in srgb, black 25%, transparent)",
    "--menu-row-height": "28px",
    "--menu-hover-fill": ink(8),
    "--menu-hover-radius": "6px",
    "--menu-separator": ink(10),
    "--menu-separator-inset": "8px",
    "--menu-label-color": ink(50),
    "--menu-label-weight": "400",
    "--menu-shortcut-color": ink(45),
    "--menu-subtitle-color": ink(45),
    "--menu-submenu-offset": "4px",
  },
};

/** The look's tokens on :root, as its stylesheet would set them; removed when the variant changes. */
function useLookTokens(look: Look) {
  useLayoutEffect(() => {
    const style = document.createElement("style");
    style.dataset.menuLook = look;
    const tokens = Object.entries(MENU_LOOKS[look]).map(([name, value]) => `${name}: ${value};`);
    style.textContent = `:root { ${tokens.join(" ")} }`;
    document.head.append(style);
    return () => style.remove();
  }, [look]);
}

function MenuLooksGallery({ look = "cmux" }: Props) {
  useLookTokens(look);
  return (
    <div className="menu-gallery-stage" data-look={look}>
      <Menu>
        <MenuButton className="menu-gallery-trigger" label="Open session menu">
          Session
        </MenuButton>
        <MenuPopup label="Session menu" className="menu-gallery-popup">
          <MenuItem shortcut="G">Open PR</MenuItem>
          <Submenu label="Open in">
            <MenuGroup label="Open in">
              <MenuItem shortcut="1">New window</MenuItem>
              <MenuItem shortcut="2">Cursor</MenuItem>
              <MenuItem shortcut="3">VS Code</MenuItem>
              <MenuItem shortcut="4">Finder</MenuItem>
            </MenuGroup>
            <MenuSeparator />
            <MenuGroup label="Continue in">
              <MenuItem shortcut="5" subtitle="Runs without your computer">
                Cloud
              </MenuItem>
            </MenuGroup>
          </Submenu>
          <MenuSeparator />
          <MenuItem shortcut="P">Pin</MenuItem>
          <MenuItem shortcut="U" disabled>
            Mark as unread
          </MenuItem>
          <MenuItem shortcut="R">Rename</MenuItem>
          <MenuItem shortcut="F">Fork</MenuItem>
          <MenuSeparator />
          <MenuItem>Show nested sessions</MenuItem>
          <Submenu label="Move to section">
            <MenuItem>Today</MenuItem>
            <MenuItem>Later</MenuItem>
          </Submenu>
          <MenuSeparator />
          <MenuItem shortcut="A">Archive</MenuItem>
          <MenuItem shortcut="D" className="ui-menu-item-destructive">
            Delete
          </MenuItem>
        </MenuPopup>
      </Menu>
    </div>
  );
}

const open: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Open session menu" });
  await ctx.waitFor(() => ctx.find({ role: "menu" }));
};

const submenu: Play = async (ctx) => {
  await open(ctx);
  await ctx.focus({ role: "menuitem", name: "Open in" });
  await ctx.press("ArrowRight");
  await ctx.waitFor(() => ctx.document.querySelectorAll('[role="menu"]').length === 2);
  await ctx.waitFor(() => ctx.find({ role: "menuitem", name: /Cloud/ }));
};

export default componentEntry<Props>({
  id: "ui.menu-looks",
  title: "Menu looks: cmux, Claude, Codex, Studio",
  area: "UI primitives",
  height: 560,
  widths: { narrow: 420, normal: 640, wide: 820 },
  covers: ["ui/Menu.tsx#MenuItem", "ui/Menu.tsx#Submenu", "ui/Menu.tsx#MenuPopup"],
  anchors: [{ selector: ".menu-gallery-trigger" }],
  load: async () => MenuLooksGallery,
  styles: () => Promise.all([import("./ui.css"), import("./popupSurface.css"), import("./Menu.gallery.css")]),
  checks: {
    anchorMovePx: { value: 0, reason: "Opening a portaled menu must not move the trigger row." },
    popupLayer: { value: true, reason: "The menu and submenu must stay topmost and within the stage." },
    settleMaxMs: { value: 250, reason: "Menu open is a local interaction." },
  },
  variants: {
    cmux: { props: { look: "cmux" }, play: open },
    claude: { props: { look: "claude" }, play: open },
    codex: { props: { look: "codex" }, play: open },
    studio: { props: { look: "studio" }, play: open },
    "cmux-submenu": { props: { look: "cmux" }, play: submenu },
    "claude-submenu": { props: { look: "claude" }, play: submenu },
    "codex-submenu": { props: { look: "codex" }, play: submenu },
    "studio-submenu": { props: { look: "studio" }, play: submenu },
  },
});
