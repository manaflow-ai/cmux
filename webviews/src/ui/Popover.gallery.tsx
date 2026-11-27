// l10n-allow-file: gallery labels and fixture content are public-safe sample UI.
import { useCallback, useMemo, useRef, useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Popover, type PopoverProps, type UiAnchor, type UiVirtualAnchor } from "./Popover";

type Props = {
  side?: PopoverProps["side"];
  anchorMode?: "element" | "rect" | "virtual";
  alignRight?: boolean;
};

function GalleryPopover({ side = "bottom", anchorMode = "element", alignRight = false }: Props) {
  const [open, setOpen] = useState(false);
  const [anchorElement, setAnchorElement] = useState<HTMLButtonElement | null>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const firstAction = useRef<HTMLButtonElement>(null);
  const secondAction = useRef<HTMLButtonElement>(null);
  const setTrigger = useCallback((element: HTMLButtonElement | null) => {
    trigger.current = element;
    setAnchorElement(element);
  }, []);
  const virtual: UiVirtualAnchor = useMemo(
    () => ({
      getBoundingClientRect: () => anchorElement?.getBoundingClientRect() ?? new DOMRect(120, 100, 140, 32),
      contextElement: anchorElement ?? undefined,
    }),
    [anchorElement],
  );
  const rect = useMemo(() => ({ left: 120, top: 100, right: 260, bottom: 132 }), []);
  const anchor: UiAnchor = anchorMode === "rect" ? rect : anchorMode === "virtual" ? virtual : anchorElement;
  return (
    <div
      className="popover-gallery"
      style={{
        alignItems: "center",
        display: "flex",
        justifyContent: alignRight ? "flex-end" : "flex-start",
        minHeight: 260,
        padding: 32,
      }}
    >
      <button
        ref={setTrigger}
        type="button"
        className="popover-gallery-trigger"
        aria-expanded={open}
        aria-label="Open popover"
        onClick={() => setOpen(true)}
      >
        Open popover
      </button>
      <span className="popover-gallery-anchor" aria-hidden="true" />
      <button
        type="button"
        className="popover-gallery-outside"
        aria-label="Outside popover"
        style={{ marginInlineStart: 12 }}
        onClick={() => undefined}
      >
        Outside
      </button>
      <Popover
        open={open}
        onOpenChange={setOpen}
        anchor={anchor}
        side={side}
        label="Popover demo"
        initialFocus={firstAction}
        finalFocus={trigger}
      >
        <div className="popover-gallery-content">
          <p>Anchored content</p>
          <button ref={firstAction} type="button" onClick={() => undefined}>
            First action
          </button>
          <button ref={secondAction} type="button" onClick={() => undefined}>
            Second action
          </button>
          <button type="button" onClick={() => setOpen(false)}>
            Close popover
          </button>
        </div>
      </Popover>
    </div>
  );
}

const openClose: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Open popover" });
  await ctx.waitFor(() => ctx.find({ role: "dialog", name: "Popover demo" }));
  await ctx.click({ role: "button", name: "Close popover" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"][aria-label="Popover demo"]') === null);
};

const escapeFocus: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Open popover" });
  await ctx.waitFor(() => ctx.find({ role: "dialog", name: "Popover demo" }));
  await ctx.press("Escape");
  await ctx.waitFor(() => {
    const trigger = ctx.find({ role: "button", name: "Open popover" });
    return (
      ctx.document.querySelector('[role="dialog"][aria-label="Popover demo"]') === null &&
      ctx.document.activeElement === trigger
    );
  });
};

const outsideClick: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Open popover" });
  await ctx.waitFor(() => ctx.find({ role: "dialog", name: "Popover demo" }));
  await ctx.click({ role: "button", name: "Outside popover" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"][aria-label="Popover demo"]') === null);
};

const keyboardNavigation: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Open popover" });
  await ctx.waitFor(() => {
    const first = ctx.find({ role: "button", name: "First action" });
    return ctx.document.activeElement === first;
  });
  await ctx.press("Tab");
  await ctx.waitFor(() => ctx.document.activeElement === ctx.find({ role: "button", name: "Second action" }));
  await ctx.press("Shift+Tab");
  await ctx.waitFor(() => ctx.document.activeElement === ctx.find({ role: "button", name: "First action" }));
  await ctx.press("Escape");
};

export default componentEntry<Props>({
  id: "ui.popover",
  title: "Popover",
  area: "Agent pane",
  height: 320,
  widths: { narrow: 320, normal: 520, wide: 720 },
  anchors: [{ selector: ".popover-gallery-anchor" }],
  checks: {
    popupLayer: {
      value: true,
      reason: "The shared popover must be the top, unclipped portal layer at its sampled bounds.",
    },
    anchorMovePx: {
      value: 0,
      reason: "Opening, navigating and dismissing the popover must not move the stable page anchor.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "A portaled popover must not add flow or shift its surrounding anchor.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Popover focus and dismissal should remain responsive on the gallery host.",
    },
    settleMaxMs: {
      value: 250,
      reason: "Opening, keyboard navigation and dismissal are local interactions with a quarter-second budget.",
    },
  },
  covers: ["ui/Popover.tsx#Popover"],
  load: async () => GalleryPopover,
  variants: {
    closed: { props: {} },
    "open-close": { props: {}, play: openClose },
    "escape-focus": { props: {}, play: escapeFocus },
    "outside-click": { props: {}, play: outsideClick },
    keyboard: { props: {}, play: keyboardNavigation },
    "virtual-anchor": { props: { anchorMode: "virtual", side: "top" }, play: openClose },
    "rect-anchor": { props: { anchorMode: "rect", side: "bottom" }, play: openClose },
    "narrow-right": { props: { alignRight: true, side: "bottom" }, play: openClose },
  },
});
