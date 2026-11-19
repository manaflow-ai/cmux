// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
// The fixtures the menu experiments' gallery entries draw (MenuStyleV2.gallery.tsx,
// MenuRowStates.gallery.tsx): a workspace's right-click menu with its Split submenu, a model picker
// with the current model checked and a disabled model's reason, and an actions menu whose Open PR
// row runs async work. Not shipped.
import { useState, type ReactNode } from "react";
import type { Play } from "../gallery/play";
import { ContextMenu, type ContextMenuItem } from "./ContextMenu";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuSeparator } from "./Menu";

export type MenuScene = "workspace" | "picker" | "actions";
export type MenuTasteProps = {
  scene: MenuScene;
  /** Arms the variant pins for experiments other than its entry's own (the compare view's arm wins). */
  arms?: Record<string, string>;
  /** Open PR's work settles after this many ms (the clip: spin, then close); absent, it never does (stills). */
  settleMs?: number;
};

/** A 14 box glyph: a plain stroke shape, standing in for the app's icon pack. */
function Glyph({ d }: { d: string }) {
  return (
    <svg viewBox="0 0 14 14" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="1.3">
      <path d={d} strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}
const PENCIL = "M3 11l1-3 5.5-5.5 2 2L6 10z";
const PIN = "M7 12V8M4.5 8h5L9 3.5H5z";
const PLUS = "M7 3v8M3 7h8";
const SPLIT = "M2.5 3h9v8h-9zM7 3v8";
const TRASH = "M3.5 4.5h7M5 4.5V3h4v1.5M4.5 4.5l.5 7h4l.5-7";
const SWATCH = "M7 2.5a4.5 4.5 0 1 0 0 9a4.5 4.5 0 0 0 0-9zM7 2.5v9";

// Close Workspace sits mid-menu here, as an older layout had it: menu-style-v2 moves it last.
// Icons are all-or-none per group under v2: the first group has one on every row and keeps them; the
// Split group mixes (Copy Path has none), so v2 draws that group with no icons.
const workspaceItems = (receipt: (text: string) => void): ContextMenuItem[] => [
  {
    id: "rename",
    label: "Rename Workspace…",
    icon: <Glyph d={PENCIL} />,
    onSelect: () => receipt("Rename"),
  },
  { id: "pin", label: "Pin Workspace", icon: <Glyph d={PIN} />, onSelect: () => receipt("Pin") },
  { id: "color", label: "Workspace Color", icon: <Glyph d={SWATCH} />, onSelect: () => receipt("Color") },
  {
    id: "new-below",
    label: "New Workspace Below",
    separatorBefore: true,
    shortcut: "⌘N",
    onSelect: () => receipt("New below"),
  },
  { id: "duplicate", label: "Duplicate Workspace", onSelect: () => receipt("Duplicate") },
  {
    id: "close",
    label: "Close Workspace",
    icon: <Glyph d={TRASH} />,
    destructive: true,
    separatorBefore: true,
    shortcut: "⇧⌘W",
    onSelect: () => receipt("Close"),
  },
  {
    id: "split",
    label: "Split",
    icon: <Glyph d={SPLIT} />,
    separatorBefore: true,
    onSelect: () => {},
    submenu: [
      {
        id: "split-right",
        label: "Split Right",
        shortcut: "⌘D",
        onSelect: () => receipt("Split right"),
      },
      {
        id: "split-down",
        label: "Split Down",
        shortcut: "⇧⌘D",
        onSelect: () => receipt("Split down"),
      },
      { id: "split-left", label: "Split Left", onSelect: () => receipt("Split left") },
      { id: "split-up", label: "Split Up", onSelect: () => receipt("Split up") },
    ],
  },
  {
    id: "new-tab",
    label: "New Tab",
    icon: <Glyph d={PLUS} />,
    shortcut: "⌘T",
    onSelect: () => receipt("New tab"),
  },
  { id: "copy-path", label: "Copy Path", onSelect: () => receipt("Copy path") },
];

function Stage({ children, receipt }: { children: ReactNode; receipt: string }) {
  return (
    <div className="menu-taste-stage">
      {children}
      <output className="menu-taste-receipt" data-testid="menu-taste-receipt" aria-live="polite">
        {receipt}
      </output>
    </div>
  );
}

export function MenuTasteGallery({ scene, arms, settleMs }: MenuTasteProps) {
  // The variant's pinned arms, under any the stage frame set from the URL (the compare view's).
  useState(() => {
    if (arms) globalThis.cmuxExperiments = { ...arms, ...globalThis.cmuxExperiments };
    return null;
  });
  const [receipt, setReceipt] = useState("Ready");
  const [model, setModel] = useState("opus");
  if (scene === "workspace")
    return (
      <Stage receipt={receipt}>
        <ContextMenu items={workspaceItems(setReceipt)}>
          <button type="button" className="menu-taste-target" data-testid="workspace-row">
            Workspace: website
          </button>
        </ContextMenu>
      </Stage>
    );
  if (scene === "picker")
    return (
      <Stage receipt={`${receipt} · ${model}`}>
        <Menu>
          <MenuButton className="menu-taste-trigger" label="Model" data-menu="model">
            Claude Opus
          </MenuButton>
          <MenuPopup label="Model" className="menu-taste-popup">
            <MenuRadioGroup value={model} onValueChange={setModel}>
              <MenuRadioItem value="opus" closeOnClick shortcut="⌘1">
                Claude Opus
              </MenuRadioItem>
              <MenuRadioItem value="sonnet" closeOnClick shortcut="⌘2">
                Claude Sonnet
              </MenuRadioItem>
              <MenuRadioItem value="haiku" closeOnClick shortcut="⌘3">
                Claude Haiku
              </MenuRadioItem>
              <MenuRadioItem value="codex" closeOnClick disabled reason="Needs sign-in">
                Codex
              </MenuRadioItem>
            </MenuRadioGroup>
            <MenuSeparator />
            <MenuItem onSelect={() => setReceipt("Manage models")}>Manage Models…</MenuItem>
          </MenuPopup>
        </Menu>
      </Stage>
    );
  return (
    <Stage receipt={receipt}>
      <Menu>
        <MenuButton className="menu-taste-trigger" label="Actions" data-menu="actions">
          Actions
        </MenuButton>
        <MenuPopup label="Actions" className="menu-taste-popup">
          {/* Without settleMs its work never settles, so the still holds the row mid-spin. */}
          <MenuItem
            async
            shortcut="⌥⌘P"
            onSelect={() =>
              new Promise<void>((done) => {
                setReceipt("Opening PR");
                if (settleMs !== undefined)
                  setTimeout(() => {
                    setReceipt("Opened PR");
                    done();
                  }, settleMs);
              })
            }
          >
            Open PR
          </MenuItem>
          <MenuItem async onSelect={() => new Promise<void>(() => setReceipt("Restarting"))}>
            Restart Agent
          </MenuItem>
          <MenuItem shortcut="⇧⌘C" onSelect={() => setReceipt("Copied")}>
            Copy Branch Name
          </MenuItem>
          <MenuSeparator />
          <MenuItem destructive onSelect={() => setReceipt("Stopped")}>
            Stop Agent
          </MenuItem>
        </MenuPopup>
      </Menu>
    </Stage>
  );
}

/** The workspace menu open at the row, its Split submenu open beside it. */
export const openWorkspaceSplit: Play = async (ctx) => {
  await ctx.contextMenu({ testId: "workspace-row" });
  await ctx.waitFor(() => ctx.find({ role: "menu" }));
  await ctx.hover({ role: "menuitem", name: "Split" });
  await ctx.waitFor(() => ctx.document.querySelectorAll('[role="menu"]').length === 2);
};

/** The model picker open, the current model checked. */
export const openPicker: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Model" });
  await ctx.waitFor(() => ctx.find({ role: "menu" }));
};

/** The actions menu open and Open PR picked: under menu-row-states it spins, the menu kept open. */
export const openPrMidSpin: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Actions" });
  await ctx.waitFor(() => ctx.find({ role: "menu" }));
  await ctx.click({ role: "menuitem", name: "Open PR" });
  await ctx.waitFor(
    () => ctx.document.querySelector("[data-pending]") !== null || ctx.document.querySelector('[role="menu"]') === null,
  );
};

/** Open PR picked and its work settled: the menu has closed and the receipt reads "Opened PR". */
export const openPrSettled: Play = async (ctx) => {
  await openPrMidSpin(ctx);
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]') === null);
};

/** The scene's menu open, whichever scene the variant draws (the compare view's one script). */
export const openSceneMenu: Play = async (ctx) => {
  if (ctx.document.querySelector('[data-testid="workspace-row"]')) return openWorkspaceSplit(ctx);
  if (ctx.document.querySelector('[data-menu="model"]')) return openPicker(ctx);
  return openPrMidSpin(ctx);
};
