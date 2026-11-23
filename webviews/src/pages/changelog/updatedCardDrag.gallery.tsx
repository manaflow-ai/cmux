// l10n-allow-file: gallery fixtures (stand-in sidebar rows), not shipped UI.
// The Updated card dragged in a sidebar (Leo 2026-11-07: "what if you could, like, drag around the
// updated to nightly, and you can drag that up to the top if you wanted to?"). A stage stands in for
// the sidebar: its list, the card's two places (the bottom card slot and the top of the list), and
// the native host's part, which moves the card by the offset the page reports and settles it at its
// new place on the spring. The three feels are the toasts' (ui/NoticeDeck.tsx).
import { useLayoutEffect, useRef, useState, type CSSProperties } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import type { UpdateHighlights } from "./updateHighlights";
import { UpdatedCard } from "./UpdateSurfaces";
import { type CardDragFeel, type CardDragHost, type CardRow } from "./updatedCardDrag";

const data: UpdateHighlights = {
  version: "1.0.0-nightly.3845050428001",
  build: "3845050428001",
  fromVersion: "1.0.0-nightly.410",
  fromBuild: "3720357960410",
  date: "2026-10-12",
  builtAt: "2026-10-12T19:38:52Z",
  head: "a9d1434de781a18ebae84d93d2b5a803864f5839",
  source: "whatsNew",
  language: "en",
  items: [
    { id: "workspace-groups", title: "Workspace groups you can see at a glance", summary: null, category: "new" },
    { id: "undo-tab-close", title: "Undo a tab close from a toast", summary: null, category: "new" },
  ],
  moreCount: 0,
  changelog: { from: "1.0.0-nightly.410", to: "1.0.0-nightly.414" },
};

const ROWS = ["cmux", "agent-pane polish", "nightly triage", "docs", "release notes", "fleet", "design refs"];
/** The gap between the card and the ends of its area (the slot's Metrics.space2). */
const GAP = 8;

type Props = { feel: CardDragFeel; anchor?: CardRow; previewOpen?: boolean };

function SidebarDragStage({ feel, anchor: initial = "bottom", previewOpen = false }: Props) {
  const [strings] = useState(() => createStrings(table));
  const [anchor, setAnchor] = useState<CardRow>(initial);
  const [near, setNear] = useState<CardRow | undefined>();
  const [closed, setClosed] = useState(false);
  const stage = useRef<HTMLDivElement | null>(null);
  const card = useRef<HTMLDivElement | null>(null);
  // Where a dropped card was, relative to its new place, until it has settled there.
  const settle = useRef<{ x: number; y: number } | null>(null);
  const offset = (value: { x: number; y: number } | null, settling = false) => {
    const element = card.current;
    if (!element) return;
    if (settling) element.dataset.settling = "";
    else delete element.dataset.settling;
    element.style.translate = value ? `${value.x}px ${value.y}px` : "";
  };
  useLayoutEffect(() => {
    const from = settle.current;
    if (!from) return;
    settle.current = null;
    // From where it was let go, then on the spring to its place.
    offset(from);
    void card.current?.getBoundingClientRect();
    requestAnimationFrame(() => offset(null, true));
  }, [anchor]);
  const host: CardDragHost = {
    place: () => {
      const area = stage.current?.getBoundingClientRect();
      const rest = card.current?.querySelector(".wn-card-rest")?.getBoundingClientRect();
      if (!area || !rest) return undefined;
      return { anchor, above: rest.top - area.top - GAP, below: area.bottom - GAP - rest.bottom };
    },
    move: (value) => offset(value),
    drop: (row, value) => {
      if (row === anchor) {
        offset(null, true);
        return;
      }
      const before = card.current?.getBoundingClientRect();
      const area = stage.current?.getBoundingClientRect();
      if (!before || !area) return;
      // The new place's top, as the stage lays the card out there.
      const height = before.height;
      const top = row === "top" ? area.top + GAP : area.bottom - GAP - height;
      settle.current = { x: value.x, y: before.top - top };
      setAnchor(row);
    },
    dismiss: () => setClosed(true),
    hold: feel === "ghosts" ? setNear : undefined,
  };
  return (
    <div
      ref={stage}
      className="wn-drag-stage"
      style={
        {
          position: "relative",
          width: 260,
          height: 420,
          overflow: "hidden",
          colorScheme: "dark",
          background: "#2a2a2a",
          color: "#d4d4d4",
          "--glass-surface": "#1e1e1e",
          "--cmux-surface-solid": "#1e1e1e",
          "--cmux-text": "#d4d4d4",
          "--page-text": "#d4d4d4",
          "--page-text-2": "color-mix(in srgb, #d4d4d4 70%, transparent)",
          "--page-text-3": "color-mix(in srgb, #d4d4d4 50%, transparent)",
          "--page-hover": "color-mix(in srgb, #d4d4d4 6%, transparent)",
        } as CSSProperties
      }
    >
      <ul
        className="wn-drag-list"
        style={{
          position: "absolute",
          inset: anchor === "top" ? "calc(var(--grid-base, 4px) * 16) 0 0" : "0 0 calc(var(--grid-base, 4px) * 16)",
          margin: 0,
          padding: "8px 12px",
          listStyle: "none",
          fontSize: "var(--text-content)",
        }}
      >
        {ROWS.map((row) => (
          <li key={row} style={{ padding: "calc(var(--grid-base, 4px) * 1.5) 0", color: "var(--page-text-2)" }}>
            {row}
          </li>
        ))}
      </ul>
      {feel === "ghosts" && near !== undefined && (
        <>
          <div className="wn-drag-ghost" data-anchor="top" data-near={near === "top" ? "" : undefined} />
          <div className="wn-drag-ghost" data-anchor="bottom" data-near={near === "bottom" ? "" : undefined} />
        </>
      )}
      {!closed && (
        <div
          ref={card}
          className="wn-drag-card"
          style={{ position: "absolute", left: 12, right: 12, ...(anchor === "top" ? { top: GAP } : { bottom: GAP }) }}
        >
          <UpdatedCard
            data={data}
            strings={strings}
            actions={{ openChangelog: () => undefined, dismiss: () => setClosed(true) }}
            anchor={anchor}
            drag={host}
            dragFeel={feel}
            previewOpen={previewOpen}
          />
        </div>
      )}
    </div>
  );
}

// Held halfway up the sidebar, over the list's middle rows.
const holding: Play = async (ctx) => {
  await ctx.pointer.down({ selector: ".wn-card-note" });
  await ctx.pointer.move({ selector: ".wn-drag-list li:nth-child(4)" });
  await ctx.waitFor(() => ctx.document.querySelector(".wn-updated[data-dragging]"));
};

// Dropped near the top: the card settles at the top place and the list makes room under it.
const toTop: Play = async (ctx) => {
  await ctx.pointer.down({ selector: ".wn-card-note" });
  await ctx.pointer.move({ selector: ".wn-drag-list li:nth-child(1)" });
  await ctx.pointer.up({ selector: ".wn-drag-list li:nth-child(1)" });
  await ctx.waitFor(() => ctx.document.querySelector(".wn-updated[data-anchor='top']"));
};

export default componentEntry<Props>({
  id: "pages.changelog.updated-card-drag",
  title: "Updated card drag",
  area: "Pages",
  height: 440,
  covers: ["pages/changelog/UpdateSurfaces.tsx#UpdatedCard"],
  keywords: ["drag", "anchor", "updated", "sidebar", "card"],
  load: async () => SidebarDragStage,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
    await import("../../ui/glass/composerMaterial.css");
    await import("./updateSurfaces.css");
    await import("./updatedCardDrag.gallery.css");
  },
  variants: {
    "drag-spring": {
      props: { feel: "spring" },
      play: holding,
      note: "Shipped: the card follows the pointer one to one, up or down (a press moved across the line still selects its words), and settles at the nearer place on the spring. Picked over ghosts because the sidebar's card has only two places, both plain to see (the slot it left and the list's top), and outlines would need a second native surface over the list; picked over rubber because a lag in a narrow vertical track reads as the card sticking.",
    },
    "drag-rubber": {
      props: { feel: "rubber" },
      play: holding,
      note: "Option: the held card leans part of the way toward the place it would settle at.",
    },
    "drag-ghosts": {
      props: { feel: "ghosts" },
      play: holding,
      note: "Option: both places outlined while the card is held, the nearer one lit.",
    },
    "dropped-at-top": {
      props: { feel: "spring" },
      play: toTop,
      note: "Let go in the sidebar's top half: the card settles under the titlebar row, the list's top edge moves down by the card's room and its bottom takes back the slot's, in one transition. The place is remembered; the card shows there next time.",
    },
    "remembered-at-top": {
      props: { feel: "spring", anchor: "top" },
      note: "A card dragged to the top before shows there after a relaunch.",
    },
    "remembered-at-top-preview": {
      props: { feel: "spring", anchor: "top", previewOpen: true },
      note: "At the top, the hover preview opens downward over the list, under the card's two lines.",
    },
  },
});
