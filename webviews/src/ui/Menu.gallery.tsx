// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
import { useState } from "react";
import { DirectionProvider } from "@base-ui/react/direction-provider";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import {
  Menu,
  MenuButton,
  MenuCheckboxItem,
  MenuGroup,
  MenuItem,
  MenuPopup,
  MenuRadioGroup,
  MenuRadioItem,
  MenuSeparator,
  Submenu,
} from "./Menu";

type Props = { direction?: "ltr" | "rtl"; checked?: boolean; radio?: string };

function MenuGallery({
  direction = "ltr",
  checked: initialChecked = true,
  radio: initialRadio = "comfortable",
}: Props) {
  const [checked, setChecked] = useState(initialChecked);
  const [radio, setRadio] = useState(initialRadio);
  const [action, setAction] = useState("Ready");
  return (
    <div className="menu-gallery-stage" dir={direction}>
      <DirectionProvider direction={direction}>
        <Menu>
          <MenuButton className="menu-gallery-trigger" label="Open demo menu" data-menu="gallery-menu">
            Menu
          </MenuButton>
          <MenuPopup label="Demo menu" className="menu-gallery-popup">
            <MenuGroup label="View">
              <MenuItem shortcut="⌘K" onSelect={() => setAction("Command palette")}>
                Open command palette
              </MenuItem>
              <MenuCheckboxItem
                checked={checked}
                onCheckedChange={(next) => {
                  setChecked(next);
                  setAction("Sidebar toggled");
                }}
              >
                Show sidebar
              </MenuCheckboxItem>
              <MenuRadioGroup
                value={radio}
                onValueChange={(next) => {
                  setRadio(next);
                  setAction(`Density: ${next}`);
                }}
              >
                <MenuRadioItem value="comfortable">Comfortable density</MenuRadioItem>
                <MenuRadioItem value="compact" shortcut="⌥C">
                  Compact density
                </MenuRadioItem>
              </MenuRadioGroup>
            </MenuGroup>
            <MenuSeparator />
            <Submenu label="More actions">
              <MenuItem onSelect={() => setAction("Rename")}>Rename</MenuItem>
              <MenuItem onSelect={() => setAction("Duplicate")}>Duplicate</MenuItem>
              <MenuItem disabled>Unavailable action</MenuItem>
            </Submenu>
            <MenuItem disabled>Disabled item</MenuItem>
          </MenuPopup>
        </Menu>
      </DirectionProvider>
      <output className="menu-gallery-receipt" data-testid="menu-gallery-receipt" aria-live="polite">
        {action} · {checked ? "sidebar on" : "sidebar off"} · {radio}
      </output>
    </div>
  );
}

const open: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Open demo menu" });
  await ctx.waitFor(() => ctx.find({ role: "menu" }));
};

const keyboard: Play = async (ctx) => {
  await ctx.focus({ role: "button", name: "Open demo menu" });
  await ctx.press("Enter");
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => ctx.document.querySelector('[role^="menuitem"][data-highlighted]'));
  await ctx.press("Escape");
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]'));
  await ctx.waitFor(() => ctx.document.activeElement?.getAttribute("aria-label") === "Open demo menu");
};

const checkbox: Play = async (ctx) => {
  await open(ctx);
  await ctx.click({ role: "menuitemcheckbox", name: /Show sidebar/ });
  await ctx.waitFor(
    () => ctx.find({ role: "menuitemcheckbox", name: /Show sidebar/ }).getAttribute("aria-checked") === "false",
  );
};

const submenu: Play = async (ctx) => {
  await open(ctx);
  await ctx.focus({ role: "menuitem", name: "More actions" });
  await ctx.press("ArrowRight");
  await ctx.waitFor(() => ctx.document.querySelectorAll('[role="menu"]').length === 2);
  await ctx.waitFor(() => ctx.find({ role: "menuitem", name: "Rename" }));
  await ctx.press("Escape");
  await ctx.waitFor(() => ctx.document.querySelectorAll('[role="menu"]').length === 1);
  await ctx.press("Escape");
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]'));
};

const rtlSubmenu: Play = async (ctx) => {
  await open(ctx);
  await ctx.focus({ role: "menuitem", name: "More actions" });
  await ctx.press("ArrowLeft");
  await ctx.waitFor(() => ctx.document.querySelectorAll('[role="menu"]').length === 2);
};

const checkboxChecks = {
  layoutShiftMax: {
    value: 0.25,
    reason: "Checkbox feedback updates the fixture receipt after the menu item changes state.",
  },
};

export default componentEntry<Props>({
  id: "ui.menu",
  title: "Shared menu primitive",
  area: "UI primitives",
  height: 420,
  widths: { narrow: 360, normal: 560, wide: 820 },
  covers: [
    "ui/Menu.tsx#Menu",
    "ui/Menu.tsx#MenuButton",
    "ui/Menu.tsx#MenuCheckboxItem",
    "ui/Menu.tsx#MenuGroup",
    "ui/Menu.tsx#MenuItem",
    "ui/Menu.tsx#MenuPopup",
    "ui/Menu.tsx#MenuRadioGroup",
    "ui/Menu.tsx#MenuRadioItem",
    "ui/Menu.tsx#MenuSeparator",
    "ui/Menu.tsx#Submenu",
  ],
  anchors: [{ selector: ".menu-gallery-trigger" }],
  load: async () => MenuGallery,
  styles: () => Promise.all([import("./ui.css"), import("./popupSurface.css"), import("./Menu.gallery.css")]),
  checks: {
    anchorMovePx: { value: 0, reason: "Opening a portaled menu must not move the trigger row." },
    popupLayer: { value: true, reason: "The menu and submenu must stay opaque, topmost, and within the stage." },
    longFrameFailMs: {
      value: 33,
      reason: "Menu keyboard and checkbox transitions should stay within two display frames.",
    },
    settleMaxMs: { value: 250, reason: "Menu open and selection feedback are local interactions." },
  },
  variants: {
    closed: { props: {} },
    open: { props: {}, play: open },
    keyboard: { props: {}, play: keyboard },
    checkbox: { props: { checked: true }, checks: checkboxChecks, play: checkbox },
    submenu: { props: {}, play: submenu },
    rtl: { props: { direction: "rtl", checked: false, radio: "compact" }, play: rtlSubmenu },
  },
});
