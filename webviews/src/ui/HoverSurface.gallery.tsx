// The One hover look (experiments.hoverLook = one, off by default; ui/hoverLook.css ONE; Leo,
// 2026-11-22, softened: "multiple styles for hover previews plus bad-looking translucency blur,
// unacceptable"): one material for every tooltip and hover card. A transcript with a "Subagent disconnected" row, the subagent chip's hover card open
// over the rows above it, a keyed label over the composer and a title tooltip over a row: each look
// draws them all at once, in their real classes, over real text, so what reads through each veil is
// what the chat would show. `now` is today's look (the switch off): the card a clear veil over the blurred rows (the
// App's popover glass), the labels the tooltip veil over unblurred text. The others are one material,
// every surface blurring what it covers in place, at three veils: `one` is the arm as it ships,
// `menu` and `dense` try a clearer and a denser veil over it.
// l10n-allow-file: gallery fixture labels, not shipped UI.
import { useLayoutEffect, useRef } from "react";
import { componentEntry } from "../gallery/format";
import { KeyHint } from "./KeyHint";
import { attachSeeThroughBlur } from "./glass/seeThroughBlur";
import { hoverCardGlass } from "./glass/hoverCardGlass";
import { HOVER_LOOK_ATTRIBUTE, HOVER_LOOK_ONE } from "./hoverLook.experiment";

type Look = "now" | "one" | "menu" | "dense";
type Props = { look?: Look };

const ROWS = [
  "Moved the scroll anchor to the row under the pointer, so a new row above it no longer shifts the list.",
  "Ran the sidebar suite on the fleet: 214 passed, 0 failed, in 41 s.",
  "Opened manaflow-ai/cmux#50112 against feat-cmux-next with the scroll fix and its test.",
  "Waiting on CI: fast gates and web checks are running, the Mac build is queued.",
];

function HoverSurfaceGallery({ look = "one" }: Props) {
  const stage = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const root = stage.current;
    if (!root) return;
    // Every look but today's runs the One arm on the page's root, as the switch does.
    const html = document.documentElement;
    if (look === "now") html.removeAttribute(HOVER_LOOK_ATTRIBUTE);
    else html.setAttribute(HOVER_LOOK_ATTRIBUTE, HOVER_LOOK_ONE);
    const under = () => root.querySelectorAll(".hover-surface-gallery-rows > *");
    const surfaces = [...root.querySelectorAll<HTMLElement>("[data-gallery-hover]")];
    // Each surface sits where the app puts it: centered on its target, 4 px above (or below) it,
    // inside the stage.
    const stageBox = root.getBoundingClientRect();
    const gap = 4;
    // Measure every surface first, then place them, so no placement forces a second layout.
    const placements = surfaces.flatMap((surface) => {
      const target = root.querySelector(surface.dataset.galleryAnchor ?? "");
      if (!target) return [];
      const anchor = target.getBoundingClientRect();
      const box = surface.getBoundingClientRect();
      const centered = anchor.left + anchor.width / 2 - box.width / 2 - stageBox.left;
      const left = Math.max(gap, Math.min(centered, stageBox.width - box.width - gap));
      const top =
        surface.dataset.gallerySide === "bottom"
          ? anchor.bottom + gap - stageBox.top
          : anchor.top - gap - box.height - stageBox.top;
      return [{ surface, left, top }];
    });
    for (const { surface, left, top } of placements) {
      surface.style.left = `${left}px`;
      surface.style.top = `${top}px`;
    }
    // Before, only a hover card blurred what it covered; now every hover surface does.
    const blurred = look === "now" ? surfaces.filter((surface) => surface.classList.contains("ui-card")) : surfaces;
    const stops = blurred.map((surface) => attachSeeThroughBlur(surface, under, hoverCardGlass));
    return () => {
      stops.forEach((stop) => stop());
      html.removeAttribute(HOVER_LOOK_ATTRIBUTE);
    };
  }, [look]);
  return (
    <div className="hover-surface-gallery" data-look={look} ref={stage} data-hover-surface-static="">
      <div className="hover-surface-gallery-rows">
        {ROWS.map((row) => (
          <p key={row}>{row}</p>
        ))}
        <p className="hover-surface-gallery-subagent">
          Subagent disconnected: <span className="hover-surface-gallery-chip">Fix the scroll anchor and land</span>
          <span className="hover-surface-gallery-muted"> · 0s</span>
        </p>
        <p className="hover-surface-gallery-composer">Type / for commands</p>
        <p className="hover-surface-gallery-chips">
          <span>Bypass permissions</span>
          <span className="hover-surface-gallery-chip">Opus 5.5 Medium</span>
        </p>
      </div>
      <div
        className="ui-tooltip ui-card ui-glass hover-surface-gallery-card"
        data-gallery-anchor=".hover-surface-gallery-subagent .hover-surface-gallery-chip"
        data-gallery-side="top"
        role="tooltip"
        data-gallery-hover=""
      >
        <strong>Fix the scroll anchor and land</strong>
        <span className="ui-tooltip-detail">Disconnected · 0s</span>
      </div>
      <div
        className="ui-tooltip ui-glass hover-surface-gallery-label"
        data-gallery-anchor=".hover-surface-gallery-chips .hover-surface-gallery-chip"
        data-gallery-side="top"
        role="tooltip"
        data-gallery-hover=""
      >
        <KeyHint keys="⌃⌘M" className="ui-tooltip-hint" />
        <span className="ui-tooltip-text">Opus 5.5 · 65% of context used</span>
      </div>
      <div
        className="ui-title-tooltip ui-glass hover-surface-gallery-title"
        data-gallery-anchor=".hover-surface-gallery-rows > p:nth-child(3)"
        data-gallery-side="bottom"
        role="tooltip"
        data-gallery-hover=""
      >
        <span className="ui-tooltip-text">Opened manaflow-ai/cmux#50112</span>
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.hover-surface",
  title: "Hover surfaces: one material (experiments.hoverLook = one)",
  area: "UI primitives",
  height: 300,
  widths: { narrow: 520, normal: 760, wide: 960 },
  checks: {
    layoutShiftMax: { value: 0, reason: "The looks are paint only: no surface changes size." },
  },
  covers: [
    "ui/hoverLook.css",
    "ui/glass/glass.css",
    "ui/Tooltip.tsx#Tooltip",
    "ui/titleTooltips.ts#installTooltips",
    "ui/hoverSurface.ts",
  ],
  load: async () => HoverSurfaceGallery,
  styles: () => import("./HoverSurface.gallery.css"),
  variants: {
    now: { props: { look: "now" } },
    one: { props: { look: "one" } },
    menu: { props: { look: "menu" } },
    dense: { props: { look: "dense" } },
  },
});
