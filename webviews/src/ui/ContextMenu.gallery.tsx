// l10n-allow-file: gallery labels and fixture content are public-safe sample UI.
import { useMemo, useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { ContextMenu, type ContextMenuItem } from "./ContextMenu";

type Props = {
  selection?: "native" | "menu";
  disabled?: boolean;
  /** The target in the stage's bottom-right corner, as the agent pane's composer is. */
  edge?: boolean;
  /** A link-length first row, as the agent pane's Open Link item has. */
  longLabel?: boolean;
  /** A toggle row checked, one unchecked and plain rows in one menu: every label on one line. */
  mixed?: boolean;
};

function ContextMenuGallery({
  selection = "native",
  disabled = false,
  edge = false,
  longLabel = false,
  mixed = false,
}: Props) {
  const [receipt, setReceipt] = useState("Ready");
  const items = useMemo<ContextMenuItem[]>(
    () => [
      ...(mixed
        ? [
            { id: "pin", label: "Pin Tab", checked: true, onSelect: () => setReceipt("Unpinned") },
            { id: "mute", label: "Mute Tab", checked: false, onSelect: () => setReceipt("Muted") },
          ]
        : []),
      {
        id: "open",
        label: longLabel ? "Open https://example.com/docs/guides/a-very-long-path/that-would-widen-the-menu" : "Open",
        onSelect: () => setReceipt("Opened"),
      },
      {
        id: "rename",
        label: "Rename",
        disabled,
        onSelect: () => setReceipt("Renamed"),
      },
      {
        id: "delete",
        label: "Delete",
        destructive: true,
        separatorBefore: true,
        onSelect: () => setReceipt("Deleted"),
      },
    ],
    [disabled, longLabel, mixed],
  );
  return (
    <div className={`context-menu-gallery-stage${edge ? " context-menu-gallery-stage--edge" : ""}`}>
      <ContextMenu items={items} selection={selection === "menu" ? "menu" : undefined}>
        <button type="button" className="context-menu-gallery-target" data-testid="context-target">
          Right-click this item
        </button>
        <p className="context-menu-gallery-copy" data-testid="selection-target">
          Select this sentence before opening the context menu to compare native selection behavior with the app menu.
        </p>
      </ContextMenu>
      <output className="context-menu-gallery-receipt" data-testid="context-menu-gallery-receipt" aria-live="polite">
        {receipt}
      </output>
    </div>
  );
}

const open: Play = async (ctx) => {
  await ctx.contextMenu({ testId: "context-target" });
  await ctx.waitFor(() => ctx.find({ role: "menu" }));
};

const keyboard: Play = async (ctx) => {
  await open(ctx);
  await ctx.press("ArrowDown");
  await ctx.press("Enter");
  await ctx.waitFor(
    () => ctx.document.querySelector('[data-testid="context-menu-gallery-receipt"]')?.textContent === "Renamed",
  );
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]'));
  await ctx.waitFor(() => ctx.document.activeElement === ctx.find({ testId: "context-target" }));
};

/** Shift-F10 on the focused control opens the menu below it; Escape gives focus back. */
const keyOpen: Play = async (ctx) => {
  await ctx.focus({ testId: "context-target" });
  await ctx.press("Shift+F10");
  await ctx.waitFor(() => ctx.find({ role: "menu" }));
  const target = ctx.find({ testId: "context-target" }).getBoundingClientRect();
  const menu = ctx.find({ role: "menu" }).getBoundingClientRect();
  const view = ctx.document.defaultView!;
  // Below the control at its start edge; flipped up only when there is no room below.
  const below = Math.abs(menu.top - target.bottom) <= 2;
  const flipped = Math.abs(menu.bottom - target.bottom) <= 2 && target.bottom + menu.height > view.innerHeight - 4;
  if (!(below || flipped) || Math.abs(menu.left - target.left) > 2)
    throw new Error(`the menu did not open at the control: ${JSON.stringify({ menu, target })}`);
  await ctx.press("Escape");
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]'));
  await ctx.waitFor(() => ctx.document.activeElement === ctx.find({ testId: "context-target" }));
};

const pointerFocus: Play = async (ctx) => {
  await open(ctx);
  await ctx.click({ role: "menuitem", name: "Open" });
  await ctx.waitFor(
    () => ctx.document.querySelector('[data-testid="context-menu-gallery-receipt"]')?.textContent === "Opened",
  );
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]'));
  await ctx.waitFor(() => ctx.document.activeElement === ctx.find({ testId: "context-target" }));
};

const escapeFocus: Play = async (ctx) => {
  await open(ctx);
  await ctx.press("Escape");
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]'));
  await ctx.waitFor(() => ctx.document.activeElement === ctx.find({ testId: "context-target" }));
};

const selectionMenu: Play = async (ctx) => {
  await ctx.selectText({ testId: "selection-target" });
  await ctx.contextMenu({ testId: "selection-target" });
  await ctx.waitFor(() => ctx.find({ role: "menu" }));
};

const selectionNative: Play = async (ctx) => {
  await ctx.selectText({ testId: "selection-target" });
  await ctx.contextMenu({ testId: "selection-target" });
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]'));
};

/** Opened at the window's bottom-right corner: the menu flips up and left to stay in view. */
const edgeOpen: Play = async (ctx) => {
  await open(ctx);
  const menu = ctx.find({ role: "menu" }).getBoundingClientRect();
  const view = ctx.document.defaultView!;
  if (menu.bottom > view.innerHeight || menu.right > view.innerWidth || menu.top < 0 || menu.left < 0)
    throw new Error(`the menu leaves the window: ${JSON.stringify(menu)} in ${view.innerWidth}x${view.innerHeight}`);
};

/** A link-length label ends in an ellipsis; the menu stays at most 360 px wide. */
const longLabelOpen: Play = async (ctx) => {
  await open(ctx);
  const menu = ctx.find({ role: "menu" });
  const width = menu.getBoundingClientRect().width;
  if (width > 360) throw new Error(`the menu grew to ${width}px for one long label`);
  if (menu.scrollWidth > menu.clientWidth) throw new Error("the menu scrolls sideways instead of truncating");
  const label = menu.querySelector<HTMLElement>(".ui-menu-label");
  if (!label || label.scrollWidth <= label.clientWidth) throw new Error("the long label is not truncated");
};

const disabledItem: Play = async (ctx) => {
  await open(ctx);
  await ctx.press("ArrowDown");
  await ctx.press("Enter");
  await ctx.waitFor(
    () => ctx.document.querySelector('[data-testid="context-menu-gallery-receipt"]')?.textContent === "Deleted",
  );
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]'));
};

export default componentEntry<Props>({
  id: "ui.context-menu",
  title: "Context menu",
  area: "UI primitives",
  height: 360,
  widths: { narrow: 360, normal: 560, wide: 820 },
  covers: ["ui/ContextMenu.tsx#ContextMenu"],
  anchors: [{ testId: "context-target" }],
  load: async () => ContextMenuGallery,
  styles: () => Promise.all([import("./ui.css"), import("./popupSurface.css"), import("./ContextMenu.gallery.css")]),
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Opening a portaled context menu must not move the invoking control.",
    },
    popupLayer: {
      value: true,
      reason: "The context menu must remain topmost and unclipped at the pointer.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Context-menu open, keyboard and dismissal transitions should stay responsive.",
    },
    settleMaxMs: {
      value: 250,
      reason: "Context-menu gestures and keyboard selection are local interactions.",
    },
  },
  variants: {
    closed: { props: {} },
    open: { props: {}, play: open },
    keyboard: { props: {}, play: keyboard },
    "key-open": { props: {}, play: keyOpen },
    "pointer-focus": { props: {}, play: pointerFocus },
    "escape-focus": { props: {}, play: escapeFocus },
    "selection-menu": { props: { selection: "menu" }, play: selectionMenu },
    "selection-native": {
      props: { selection: "native" },
      play: selectionNative,
    },
    disabled: { props: { disabled: true }, play: disabledItem },
    edge: { props: { edge: true }, play: edgeOpen },
    "long-label": { props: { longLabel: true }, play: longLabelOpen },
    mixed: {
      note: "A checked toggle, an unchecked toggle and plain rows in one menu: every label starts on one line.",
      props: { mixed: true },
      play: open,
    },
  },
});
