// l10n-allow-file: gallery labels and content are deterministic fixture text.
// Leo 2026-11-22: "to be honest, when hovering your mouse to the sidebar, do you want to see the thumb? claude code,
// you dont see it... unless you scroll first. hovering only doesnt show." A scroller thumb shows only while its
// list scrolls (plus the linger) and never from the pointer alone; a resize handle over the scrollbar lane wins
// the press. The page's real scroller rules and pointer marks (scrollers.ts `installScrollers`) draw it here.
import { useEffect } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { installScrollers, RESIZE_HANDLE_PROPS, SCROLLING_ATTRIBUTE, SCROLLING_HIDE_MS } from "../scrollers";

type Props = Record<string, never>;

const LIST = "scroller-gallery-list";
const HANDLE = "scroller-gallery-handle";

function ScrollerGallery(_props: Props) {
  useEffect(() => {
    const root = document.documentElement;
    const before = root.getAttribute("data-scrollers");
    root.setAttribute("data-scrollers", "legacy");
    installScrollers(document);
    return () => {
      if (before === null) root.removeAttribute("data-scrollers");
      else root.setAttribute("data-scrollers", before);
    };
  }, []);
  return (
    <div data-gallery-capture="" style={{ position: "relative", width: 240, height: 200 }}>
      <div data-testid={LIST} style={{ height: 200, overflowY: "auto", paddingRight: 4 }}>
        {Array.from({ length: 40 }, (_, index) => (
          <div key={index} style={{ padding: "var(--ds-space-1) var(--ds-space-3)" }}>
            Row {index + 1}
          </div>
        ))}
      </div>
      <div
        data-testid={HANDLE}
        {...RESIZE_HANDLE_PROPS}
        style={{ position: "absolute", top: 0, bottom: 0, right: -4, width: 8, cursor: "col-resize" }}
      />
    </div>
  );
}

const scrolledList = (ctx: Parameters<Play>[0]) => ctx.find({ testId: LIST }) as HTMLElement;
const isScrolling = (ctx: Parameters<Play>[0]) => scrolledList(ctx).hasAttribute(SCROLLING_ATTRIBUTE);

const hoverOnly: Play = async (ctx) => {
  await ctx.hover({ testId: LIST });
};

const scrolled: Play = async (ctx) => {
  await ctx.scroll({ testId: LIST }, 200);
  await ctx.hover({ testId: LIST });
};

const idleAfterScroll: Play = async (ctx) => {
  await ctx.scroll({ testId: LIST }, 200);
  await ctx.waitFor(() => !isScrolling(ctx), { capMs: SCROLLING_HIDE_MS * 3 });
};

const nearHandle: Play = async (ctx) => {
  await ctx.hover({ testId: HANDLE });
};

export default componentEntry<Props>({
  id: "ui.scroller-thumb",
  title: "Scroller thumb",
  area: "UI primitives",
  height: 260,
  keywords: ["scrollbar", "thumb", "hover", "resize", "handle"],
  covers: ["scrollers.ts"],
  load: async () => ScrollerGallery,
  variants: {
    "rest-hover": {
      props: {},
      play: hoverOnly,
      note: "At rest, pointer over the list: no thumb. Hover alone never shows it.",
    },
    scrolled: { props: {}, play: scrolled, note: "Just scrolled: the thumb shows, and holds while the pointer stays." },
    "idle-after-scroll": { props: {}, play: idleAfterScroll, note: "Idle after the scroll: the thumb has faded." },
    "near-handle": {
      props: {},
      play: nearHandle,
      note: "Pointer on the resize handle over the lane: the handle wins, no thumb.",
    },
  },
});
