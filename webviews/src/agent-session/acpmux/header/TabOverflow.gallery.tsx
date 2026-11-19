// l10n-allow-file: gallery fixture data, not shipped UI.
// What a strip too narrow for its tabs does under experiments.tabOverflow (Settings > Experimental > Tab Bar, taste
// build 14): 20 tabs of one fixed width, the close × on the hovered and the selected tab only, the selected tab kept in
// view. chevrons scrolls with edge fades and a chevron on each hidden edge; more-menu moves the tabs that don't fit
// into a More menu (the selected one always stays); all-tabs fades the trailing edge under a pinned All tabs pill.
// The strip is native (PaneContentView); this draws its geometry. The strip's width is a CSS variable, and each
// *-resize variant animates it from 1200px to 420px and back. Per frame the layout is flex alone: one read of the
// strip's width per resize, written to DOM attributes, and React state only when more-menu's fitting count changes.
import { type CSSProperties, useLayoutEffect, useRef, useState } from "react";
import { componentEntry } from "../../../gallery/format";

type Mode = "chevrons" | "more-menu" | "all-tabs";
type Props = { mode: Mode; resize?: boolean; width?: number; hoverIndex?: number; menuOpen?: boolean };

const TABS = [
  "studio-mac/menubar-chats-menu",
  "GitHub",
  "README.md",
  "zsh: ~/src/cmux",
  "Pull request #4812",
  "cargo test",
  "design notes",
  "tabRow.ts",
  "Settings",
  "build log",
  "fleet status",
  "Changelog",
  "header.css",
  "release checklist",
  "Inbox",
  "deploy preview",
  "PaneContentView.swift",
  "npm run dev",
  "History",
  "New Tab",
];
const SELECTED = 12;
const TAB_W = 140;
const PAD = 4;
const MORE_W = 84;
const PILL_W = 92;

function Tab({ index, hovered }: { index: number; hovered: boolean }) {
  const selected = index === SELECTED;
  return (
    <div
      className="ttb-tab"
      role="tab"
      aria-selected={selected}
      data-selected={selected ? "" : undefined}
      data-hover={hovered ? "" : undefined}
      title={TABS[index]}
    >
      <span className="ttb-icon" aria-hidden />
      <span className="ttb-label">{TABS[index]}</span>
      <span className="ttb-close" aria-label="Close Tab">
        ×
      </span>
    </div>
  );
}

/// Keeps the selected tab inside the scroller's visible span, from arithmetic on the fixed tab width (no per-tab read).
function keepSelectedInView(scroller: HTMLElement, leading: number, trailing: number) {
  const start = PAD + SELECTED * TAB_W;
  const end = start + TAB_W;
  const view = scroller.clientWidth;
  if (start - leading < scroller.scrollLeft) scroller.scrollLeft = Math.max(0, start - leading);
  else if (end + trailing > scroller.scrollLeft + view) scroller.scrollLeft = end + trailing - view;
}

function TabOverflow({ mode, resize, width, hoverIndex = SELECTED - 1, menuOpen = true }: Props) {
  const rootRef = useRef<HTMLDivElement>(null);
  const scrollerRef = useRef<HTMLDivElement>(null);
  const readoutRef = useRef<HTMLSpanElement>(null);
  const [fits, setFits] = useState(TABS.length);

  useLayoutEffect(() => {
    const root = rootRef.current;
    const scroller = scrollerRef.current;
    if (!root || !scroller) return;
    // One read per scroll or resize; the fades and chevrons follow two attributes.
    const edges = () => {
      const max = scroller.scrollWidth - scroller.clientWidth;
      root.toggleAttribute("data-more-start", scroller.scrollLeft > 1);
      root.toggleAttribute("data-more-end", scroller.scrollLeft < max - 1);
    };
    const measure = () => {
      const stripWidth = root.clientWidth;
      if (readoutRef.current) readoutRef.current.textContent = `strip width ${Math.round(stripWidth)}px`;
      if (mode === "more-menu") {
        const all = Math.floor((stripWidth - 2 * PAD) / TAB_W);
        // React bails out when the count is unchanged, so a resize renders only when a tab moves into or out of More.
        setFits(all >= TABS.length ? TABS.length : Math.max(1, Math.floor((stripWidth - 2 * PAD - MORE_W) / TAB_W)));
        return;
      }
      keepSelectedInView(scroller, mode === "chevrons" ? 40 : 8, mode === "chevrons" ? 40 : PILL_W + 16);
      edges();
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(root);
    scroller.addEventListener("scroll", edges, { passive: true });
    return () => {
      observer.disconnect();
      scroller.removeEventListener("scroll", edges);
    };
  }, [mode]);

  const page = (direction: 1 | -1) =>
    scrollerRef.current?.scrollBy({ left: direction * (scrollerRef.current.clientWidth - 80), behavior: "smooth" });

  let shown = TABS.map((_, index) => index);
  let hidden: number[] = [];
  if (mode === "more-menu" && fits < TABS.length) {
    // The selected tab always stays on the strip, in the last slot when it would not fit in order.
    shown = SELECTED < fits ? shown.slice(0, fits) : [...shown.slice(0, fits - 1), SELECTED];
    hidden = TABS.map((_, index) => index).filter((index) => !shown.includes(index));
  }

  return (
    <div className="ttb-ovf-stage">
      <span className="ttb-ovf-width" ref={readoutRef} />
      <div
        ref={rootRef}
        className="ttb-ovf"
        data-mode={mode}
        data-resize={resize ? "" : undefined}
        style={width ? ({ "--ttb-strip-width": `${width}px` } as CSSProperties) : undefined}
      >
        {mode === "chevrons" ? (
          <button
            type="button"
            className="ttb-ovf-button ttb-ovf-chevron"
            data-edge="start"
            aria-label="Scroll tabs left"
            onClick={() => page(-1)}
          >
            ‹
          </button>
        ) : null}
        <div className="ttb-ovf-scroller" ref={scrollerRef} role="tablist">
          {shown.map((index) => (
            <Tab key={index} index={index} hovered={index === hoverIndex} />
          ))}
        </div>
        {mode === "chevrons" ? (
          <button
            type="button"
            className="ttb-ovf-button ttb-ovf-chevron"
            data-edge="end"
            aria-label="Scroll tabs right"
            onClick={() => page(1)}
          >
            ›
          </button>
        ) : null}
        {mode === "more-menu" && hidden.length > 0 ? (
          <>
            <button
              type="button"
              className="ttb-ovf-button"
              data-open={menuOpen ? "" : undefined}
              aria-expanded={menuOpen}
            >
              {hidden.length} more ▾
            </button>
            {menuOpen ? (
              <div className="ttb-ovf-menu" role="menu">
                {hidden.map((index) => (
                  <div key={index} className="ttb-ovf-menu-row" role="menuitem">
                    <span className="ttb-icon" aria-hidden />
                    {TABS[index]}
                  </div>
                ))}
              </div>
            ) : null}
          </>
        ) : null}
        {mode === "all-tabs" ? (
          <button type="button" className="ttb-ovf-button ttb-ovf-pill">
            All tabs
          </button>
        ) : null}
      </div>
    </div>
  );
}

const NOTES: Record<Mode, string> = {
  chevrons: "Scrolls: each hidden edge fades and carries a chevron; the selected tab scrolls into view.",
  "more-menu": "The tabs that don't fit go into More (open here); the selected tab always stays on the strip.",
  "all-tabs": "Scrolls under a pinned All tabs pill, the trailing edge fading out beneath it.",
};

const MODES: Mode[] = ["chevrons", "more-menu", "all-tabs"];

export default componentEntry<Props>({
  id: "agent-pane.tab-overflow",
  title: "Tab overflow (experiments.tabOverflow)",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 440,
  widths: { narrow: 460, normal: 760, wide: 1240 },
  keywords: ["tab strip", "overflow", "chevrons", "more menu", "all tabs", "resize", "taste"],
  covers: ["agent-session/acpmux/header/tabRow.ts"],
  load: async () => TabOverflow,
  styles: () => import("./TabStrip.gallery.css"),
  variants: Object.fromEntries(
    MODES.flatMap((mode) => [
      [mode, { note: NOTES[mode], props: { mode } }],
      [
        `${mode}-resize`,
        { note: `${NOTES[mode]} The strip's width animates 1200px → 420px → 1200px.`, props: { mode, resize: true } },
      ],
    ]),
  ),
});
