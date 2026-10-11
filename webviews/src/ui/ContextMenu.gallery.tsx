// l10n-allow-file: gallery labels and fixture content are public-safe sample UI.
import { useMemo, useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { ContextMenu, type ContextMenuItem } from "./ContextMenu";

type Props = {
  selection?: "native" | "menu";
  disabled?: boolean;
};

function ContextMenuGallery({ selection = "native", disabled = false }: Props) {
  const [receipt, setReceipt] = useState("Ready");
  const items = useMemo<ContextMenuItem[]>(
    () => [
      { id: "open", label: "Open", onSelect: () => setReceipt("Opened") },
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
    [disabled],
  );
  return (
    <div className="context-menu-gallery-stage">
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
    "pointer-focus": { props: {}, play: pointerFocus },
    "escape-focus": { props: {}, play: escapeFocus },
    "selection-menu": { props: { selection: "menu" }, play: selectionMenu },
    "selection-native": {
      props: { selection: "native" },
      play: selectionNative,
    },
    disabled: { props: { disabled: true }, play: disabledItem },
  },
});
