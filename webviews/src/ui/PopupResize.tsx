// The grips that make a popup resizable, as the model menu is (cmux#51745: "can we do it for the other
// dropdowns as well"). `Popover` and `MenuPopup` draw them when given `resize`. Each grip sits on an
// edge away from the anchor, read from where the popup actually opened (its data-side and data-align):
// a dropdown above its chip (the composer's top row) grows up, right and up-right from the top edge,
// the right edge and the top-right corner; one below its chip (the bottom row) grows down and away from
// the side it lines up with, as the model menu does. The drag is the model menu's (popupResizeDrag.ts). The
// size is kept per dropdown for every composer and page; a double-click on a grip goes back to the
// default.
import { useCallback, useLayoutEffect, useRef, useState, useSyncExternalStore } from "react";
import { sizeStore, startPopupResize, type PopupResizeAxes, type SizeStore } from "./popupResizeDrag";

/** Makes a popup resizable. */
export interface PopupResizeOptions {
  /** The name its size is kept under, one per dropdown (for example "composer.folder"); every popup
   *  with the same id shares one size. */
  id: string;
  /** The narrowest a drag makes it, in px. */
  minWidth?: number;
  /** The shortest a drag makes it, in px. */
  minHeight?: number;
}

export const POPUP_RESIZE_MIN_WIDTH = 200;
export const POPUP_RESIZE_MIN_HEIGHT = 120;

type Sizes = { width: SizeStore; height: SizeStore };
const stores = new Map<string, Sizes>();

/// The kept width and height of the popups resized under `id` (one pair per id, shared by every popup
/// on the page that uses it).
export function popupSizeStores(id: string): Sizes {
  let sizes = stores.get(id);
  if (!sizes) {
    sizes = {
      width: sizeStore(`cmux.popupSize.${id}.width`, 1),
      height: sizeStore(`cmux.popupSize.${id}.height`, 1),
    };
    stores.set(id, sizes);
  }
  return sizes;
}

/** The size the person dragged the popups under `id` to, in px; undefined: its default. */
export function popupSize(id: string): { width?: number; height?: number } {
  const sizes = popupSizeStores(id);
  const width = sizes.width.get();
  const height = sizes.height.get();
  return { ...(width !== undefined ? { width } : {}), ...(height !== undefined ? { height } : {}) };
}

/** Keeps a size for the popups under `id`; an undefined dimension goes back to its default. */
export function setPopupSize(id: string, size: { width?: number; height?: number }) {
  const sizes = popupSizeStores(id);
  if ("width" in size) sizes.width.set(size.width);
  if ("height" in size) sizes.height.set(size.height);
}

type Placement = { side: "top" | "bottom"; align: "start" | "end" };

function placementOf(popup: HTMLElement | null, fallback: Placement): Placement {
  const side = popup?.dataset.side;
  const align = popup?.dataset.align;
  return {
    side: side === "top" || side === "bottom" ? side : fallback.side,
    align: align === "end" ? "end" : align === "start" || align === "center" ? "start" : fallback.align,
  };
}

const AVAILABLE_WIDTH = "var(--available-width, calc(100vw - 24px))";

/// Sizes `popup` to the kept width and height, or back to its stylesheet's default where none is kept.
/// A kept size never runs past the room the positioner reports. Only the sizes this (or a drag) set
/// are cleared (data-resized-width and -height mark them), never another owner's inline style.
function applySize(popup: HTMLElement, width: number | undefined, height: number | undefined, least: number) {
  if (width !== undefined) {
    popup.style.width = `min(${width}px, ${AVAILABLE_WIDTH})`;
    popup.style.minWidth = `min(${least}px, ${AVAILABLE_WIDTH})`;
    popup.style.maxWidth = AVAILABLE_WIDTH;
    popup.dataset.resizedWidth = "";
  } else if (popup.dataset.resizedWidth !== undefined) {
    popup.style.width = "";
    popup.style.minWidth = "";
    popup.style.maxWidth = "";
    delete popup.dataset.resizedWidth;
  }
  if (height !== undefined) {
    const size = `min(${height}px, var(--available-height, ${height}px))`;
    popup.style.minHeight = "";
    popup.style.height = size;
    popup.style.maxHeight = size;
    popup.dataset.resizedHeight = "";
  } else if (popup.dataset.resizedHeight !== undefined) {
    popup.style.minHeight = "";
    popup.style.height = "";
    popup.style.maxHeight = "";
    delete popup.dataset.resizedHeight;
  }
}

/// The three grips, drawn as the popup's own children. `side` and `align` are what the popup asked
/// for; where it actually opened (a flip) wins once it is placed.
export function PopupResizeGrips({
  resize,
  side,
  align,
}: {
  resize: PopupResizeOptions;
  side: "top" | "bottom";
  align: "start" | "end";
}) {
  const { id } = resize;
  const leastWidth = resize.minWidth ?? POPUP_RESIZE_MIN_WIDTH;
  const leastHeight = resize.minHeight ?? POPUP_RESIZE_MIN_HEIGHT;
  const sizes = popupSizeStores(id);
  const width = useSyncExternalStore(sizes.width.subscribe, sizes.width.get, sizes.width.get);
  const height = useSyncExternalStore(sizes.height.subscribe, sizes.height.get, sizes.height.get);
  const [popup, setPopup] = useState<HTMLElement | null>(null);
  const [placed, setPlaced] = useState<Placement>({ side, align });
  // A drag in progress owns the size: a render meanwhile (a streaming reply) never resets it.
  const dragging = useRef(false);
  const holdPopup = useCallback((grip: HTMLDivElement | null) => setPopup(grip?.parentElement ?? null), []);
  // Where the popup opened, followed as the positioner places it.
  useLayoutEffect(() => {
    const fallback = { side, align };
    setPlaced(placementOf(popup, fallback));
    if (!popup || typeof MutationObserver === "undefined") return;
    const observer = new MutationObserver(() => {
      const next = placementOf(popup, fallback);
      setPlaced((last) => (last.side === next.side && last.align === next.align ? last : next));
    });
    observer.observe(popup, { attributes: true, attributeFilter: ["data-side", "data-align"] });
    return () => observer.disconnect();
  }, [popup, side, align]);
  useLayoutEffect(() => {
    if (!popup) return;
    popup.dataset.resizable = "";
    if (!dragging.current) applySize(popup, width, height, leastWidth);
  }, [popup, width, height, leastWidth]);
  const start = (event: React.PointerEvent<HTMLDivElement>, axes: PopupResizeAxes) => {
    const node = event.currentTarget.parentElement;
    if (!node) return;
    const view = node.ownerDocument.defaultView;
    const box = node.getBoundingClientRect();
    const where = placementOf(node, placed);
    startPopupResize(event, {
      popup: node,
      axes,
      fromEnd: where.align === "end",
      fromTop: where.side === "top",
      least: { width: leastWidth, height: leastHeight },
      bound: {
        left: 8,
        right: (view?.innerWidth ?? box.right) - 8,
        top: 8,
        bottom: (view?.innerHeight ?? box.bottom) - 8,
      },
      onStart: () => {
        dragging.current = true;
        // The drag writes these sizes: marked, so a reset or an unchanged drag clears them again.
        if (axes !== "height") node.dataset.resizedWidth = "";
        if (axes !== "width") node.dataset.resizedHeight = "";
      },
      onEnd: (size) => {
        dragging.current = false;
        if (size.width !== undefined) sizes.width.set(size.width);
        if (size.height !== undefined) sizes.height.set(size.height);
        // Whatever the drag left, the kept size (or the default) sizes it again.
        applySize(node, sizes.width.get(), sizes.height.get(), leastWidth);
      },
    });
  };
  const edge = placed.align === "end" ? "start" : "end";
  return (
    <>
      {/* The side edge away from the one lined up with the chip: a drag sets the width. */}
      {/* oxlint-disable-next-line jsx-a11y/no-static-element-interactions -- a pointer-only grip; the width also has its default */}
      <div
        ref={holdPopup}
        className="ui-popup-resize"
        data-axis="x"
        data-edge={edge}
        aria-hidden="true"
        onPointerDown={(event) => start(event, "width")}
        onDoubleClick={() => sizes.width.set(undefined)}
      />
      {/* The top or bottom edge away from the chip: a drag sets the height. */}
      {/* oxlint-disable-next-line jsx-a11y/no-static-element-interactions -- a pointer-only grip; the height also has its default */}
      <div
        className="ui-popup-resize"
        data-axis="y"
        data-side={placed.side}
        aria-hidden="true"
        onPointerDown={(event) => start(event, "height")}
        onDoubleClick={() => sizes.height.set(undefined)}
      />
      {/* The corner between them sets both. */}
      {/* oxlint-disable-next-line jsx-a11y/no-static-element-interactions -- a pointer-only grip; both dimensions also have defaults */}
      <div
        className="ui-popup-resize"
        data-axis="both"
        data-edge={edge}
        data-side={placed.side}
        aria-hidden="true"
        onPointerDown={(event) => start(event, "both")}
        onDoubleClick={() => {
          sizes.width.set(undefined);
          sizes.height.set(undefined);
        }}
      />
    </>
  );
}
