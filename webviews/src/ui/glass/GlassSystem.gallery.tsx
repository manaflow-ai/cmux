// l10n-allow-file: gallery fixtures, not shipped UI.
// The one glass system (design/glass-system.md): every glass level of the design scale side by side,
// on the real classes, over a page of text. The stage takes the frame's theme, scheme and background
// (light or dark, opaque or over a picture), so one variant shows the levels as the page draws them
// in each appearance. The candidate numbers (before, the rulebook, denser, clearer) are arms of
// webviews/scripts/gallery/capture-states.mjs: CSS that resets the --ds-glass-* tokens, not code here.
//
// - chrome: a bar docked on the page (the root glass: --ds-glass-chrome-*).
// - popover: glass in the page that floats, as the composer and Session Info draw it.
// - menu: a menu and a hover card, the one floating material (--ds-transient-web-*).
// - chip: a tooltip, the host's contrast-fitted tint (here the level's fallback).
// - content: a card in the content layer (.ui-glass-content): near-solid, no blur (rule 2).
//
// Variants: Liquid Glass on (the gallery's base theme keeps glass on), Liquid Glass off
// (data-glass="off", the shipped default since cmux#46104) and Reduce Transparency.
import { KeyHint } from "../KeyHint";
import { type CSSProperties, useEffect } from "react";
import { componentEntry } from "../../gallery/format";

type Mode = "glass" | "off" | "reduce";
type Props = { mode: Mode; scene?: "levels" | "hover-input" };

const TEXT =
  "The build finished on the second worker. Three tests failed in the parser suite, all on the same fixture: a trailing comma after the last field. The fix is one line in the tokenizer; the rest of the run is green. Next: rerun the suite at the new head, then post the numbers on the pull request. ";

const box = (left: number, top: number, width: number, height: number): CSSProperties => ({
  position: "absolute",
  left,
  top,
  width,
  height,
  boxSizing: "border-box",
  color: "var(--cmux-text)",
  fontSize: "var(--text-body)",
});

/** The popover level as an in-page floating surface draws it (sessionInfo.css, composerStates.css). */
const POPOVER: CSSProperties = {
  "--glass-tint": "color-mix(in srgb, var(--glass-surface) var(--ds-glass-popover-tint), transparent)",
  "--glass-backdrop": "var(--ds-glass-popover-blur)",
  "--glass-elevation": "var(--elevation-2)",
  borderRadius: "var(--ds-radius-composer)",
} as CSSProperties;

const TEXT_BLOCK: CSSProperties = { position: "absolute", lineHeight: 1.55, overflow: "hidden" };

/** A block of page text placed in the sheet (gallery geometry, not UI spacing). */
const textAt = (
  top: number,
  left: number,
  right: number,
  size: { height: number } | { bottom: number },
): CSSProperties => ({
  ...TEXT_BLOCK,
  top,
  left,
  right,
  ...size,
});

const MENU_ROWS = ["Open in New Tab", "Fork Conversation", "Copy Link", "Move to Cloud", "Archive"];

function useMode(mode: Mode): void {
  useEffect(() => {
    const root = document.documentElement;
    const saved = root.getAttribute("data-glass");
    if (mode === "off") root.setAttribute("data-glass", "off");
    root.toggleAttribute("data-reduce-transparency", mode === "reduce");
    return () => {
      root.removeAttribute("data-reduce-transparency");
      if (saved === null) root.removeAttribute("data-glass");
      else root.setAttribute("data-glass", saved);
    };
  }, [mode]);
}

function GlassSystemGallery({ mode, scene = "levels" }: Props) {
  useMode(mode);
  if (scene === "hover-input") return <HoverInputScene />;
  return (
    <div
      data-testid="glass-system"
      style={{ position: "relative", height: 400, color: "var(--cmux-text)", fontSize: "var(--text-body)" }}
    >
      {/* The page's text, with a gap on the left where the content card sits in the flow (a content
          card is never over text; the floating levels are). */}
      <div style={textAt(56, 24, 24, { height: 88 })}>{TEXT.repeat(2)}</div>
      <div style={textAt(144, 370, 24, { height: 110 })}>{TEXT.repeat(2)}</div>
      <div style={textAt(254, 24, 24, { bottom: 0 })}>{TEXT.repeat(3)}</div>
      <div
        className="ui-glass"
        data-level="chrome"
        style={{
          ...box(0, 0, 760, 40),
          display: "flex",
          alignItems: "center",
          gap: "var(--ds-space-3)",
          padding: "0 var(--ds-space-4)",
        }}
      >
        <span style={{ fontWeight: "var(--weight-emphasis)" }}>Parser fixes</span>
        <span style={{ color: "var(--cmux-text-secondary)" }}>chrome · the bar docked on the page</span>
      </div>
      <div
        className="ui-glass ui-glass-content"
        data-level="content"
        style={{
          ...box(24, 150, 330, 96),
          padding: "var(--ds-space-3) var(--ds-space-4)",
          borderRadius: "var(--ui-popup-radius)",
        }}
      >
        <div style={{ color: "var(--cmux-text-secondary)" }}>content · a permission ask in the transcript</div>
        <div style={{ marginTop: "var(--ds-space-2)" }}>Allow edits to tokenizer.rs? Near-solid, no blur.</div>
      </div>
      <div
        className="ui-glass ui-glass-floats"
        data-level="popover"
        style={{ ...box(24, 270, 330, 108), ...POPOVER, padding: "var(--ds-space-3) var(--ds-space-4)" }}
      >
        <div style={{ color: "var(--cmux-text-secondary)" }}>popover · the composer, Session Info</div>
        <div style={{ marginTop: "var(--ds-space-2)" }}>
          Rerun the parser suite at the new head and post the numbers.
        </div>
      </div>
      <div
        className="ui-popup ui-glass ui-menu"
        role="menu"
        data-level="menu"
        style={{
          ...box(390, 70, 200, 0),
          height: "auto",
          padding: "var(--ui-popup-padding)",
          borderRadius: "var(--ui-popup-radius)",
        }}
      >
        {MENU_ROWS.map((row) => (
          <div
            key={row}
            role="menuitem"
            style={{
              display: "flex",
              alignItems: "center",
              height: "var(--ui-row-height)",
              padding: "0 var(--ds-space-2)",
            }}
          >
            {row}
          </div>
        ))}
      </div>
      <div
        className="ui-card ui-glass"
        data-level="menu"
        style={{
          ...box(390, 260, 250, 96),
          padding: "var(--ds-space-3)",
          borderRadius: "var(--ui-popup-radius)",
          display: "grid",
          gap: "var(--ds-space-1)",
        }}
      >
        <span style={{ color: "var(--cmux-text-secondary)" }}>Context window</span>
        <span style={{ fontWeight: "var(--weight-emphasis)" }}>91% used · 365K / 399.1K</span>
        <span>menu · a hover card</span>
      </div>
      <div
        className="ui-tooltip ui-glass"
        role="tooltip"
        data-level="chip"
        style={{
          ...box(610, 84, 0, 0),
          width: "auto",
          height: "auto",
          padding: "var(--ds-space-1) var(--ds-space-2)",
          borderRadius: "var(--ds-radius-md)",
          whiteSpace: "nowrap",
        }}
      >
        {/* key-hint-allow: a sample label naming the glass level, not a drawn shortcut. */}
        chip · a tooltip ⌘K
      </div>
    </div>
  );
}

/** Leo, 2026-11-20: a bit more glass on the chat input box, and glass everywhere, especially on the
 * hover tooltips and hover previews. The input box, two tooltips, a link's hover card and the chat
 * header's tool preview, each on its real classes, over a transcript's text: the candidates (now,
 * clearer, edge, clearer-edge) are capture arms (scripts/gallery/glass-hover-input.capture.json). */
function HoverInputScene() {
  return (
    <div
      data-testid="glass-hover-input"
      style={{ position: "relative", height: 400, color: "var(--cmux-text)", fontSize: "var(--text-body)" }}
    >
      <div style={{ ...TEXT_BLOCK, inset: "12px 24px 0" }}>{TEXT.repeat(6)}</div>
      <div
        className="ui-tooltip ui-glass"
        role="tooltip"
        style={{ ...box(32, 24, 0, 0), width: "auto", height: "auto", whiteSpace: "nowrap" }}
      >
        <span className="ui-tooltip-text">Fork Conversation</span>
        <KeyHint keys="⌘⇧D" className="ui-tooltip-hint" />
      </div>
      <div
        className="ui-title-tooltip ui-glass"
        role="tooltip"
        style={{ ...box(32, 70, 0, 0), position: "absolute", width: "auto", height: "auto", whiteSpace: "nowrap" }}
      >
        ~/src/cmux/webviews/src/ui/glass/glass.css
        <span className="ui-tooltip-detail">Opens in the Files pane</span>
      </div>
      <div
        className="ui-tooltip ui-card ui-glass ui-glass-floats cv-link-preview"
        role="tooltip"
        style={{
          ...box(300, 20, 300, 0),
          height: "auto",
          maxHeight: "none",
          borderRadius: "var(--ui-popup-radius)",
        }}
      >
        {/* The real card's content wrapper (LinkHoverCard, linkCard.css), which pads the text off the rim. */}
        <div
          className="cv-link-preview__content"
          style={{ display: "grid", gap: "var(--ds-space-1)", padding: "var(--ds-space-2) var(--ds-space-3)" }}
        >
          <span style={{ fontWeight: "var(--weight-emphasis)" }}>Fix the trailing comma in the tokenizer #4812</span>
          <span style={{ color: "var(--cmux-text-secondary)" }}>manaflow/parser · opened 2 hours ago</span>
          <span style={{ color: "var(--cmux-text-secondary)" }}>✓ 14 checks · 1 running</span>
        </div>
      </div>
      <div
        className="ui-card ui-glass acpmux-header-preview"
        role="tooltip"
        style={{ ...box(32, 118, 220, 0), position: "absolute", height: "auto", padding: "var(--ds-space-2)" }}
      >
        <div style={{ fontWeight: "var(--weight-emphasis)" }}>Split Right</div>
        <div style={{ color: "var(--cmux-text-secondary)" }}>Opens the diff beside the chat</div>
      </div>
      <section
        className="acpmux-shell"
        style={{ position: "absolute", left: 0, right: 0, bottom: 0, height: "auto", background: "transparent" }}
      >
        <div className="acpmux-composer" style={{ flex: 1, padding: "0 24px 16px" }}>
          <div className="ui-glass ui-glass-floats ui-glass-material acpmux-composer-box" style={{ minHeight: 96 }}>
            <div className="acpmux-md" style={{ padding: "12px 16px", color: "var(--agent-text)" }}>
              Rerun the parser suite at the new head, then post the numbers on the pull request.
            </div>
            <div style={{ padding: "0 var(--ds-space-4) var(--ds-space-3)", color: "var(--acpmux-composer-dim)" }}>
              Opus 5.5 · Ask before edits
            </div>
          </div>
        </div>
      </section>
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.glass-system",
  title: "One glass system",
  area: "Pages",
  height: 420,
  covers: ["ui/glass/glass.css", "agent-session/acpmux/composerStates.css", "agent-session/acpmux/header/header.css"],
  // The pane's sheets for the hover-input scene's composer, link card and header preview.
  load: async () => {
    await Promise.all([
      import("../../agent-session/shared/styles.css"),
      import("../../agent-session/acpmux/styles.css"),
      import("../../agent-session/acpmux/composerStates.css"),
      import("../../agent-session/acpmux/composerLocation.css"),
      import("../../agent-session/acpmux/chips/linkCard.css"),
      import("../../agent-session/acpmux/header/header.css"),
    ]);
    return GlassSystemGallery;
  },
  variants: {
    glass: {
      note: "Liquid Glass on: chrome, popover, menu and chip from the design scale's levels, one saturation, one edge.",
      props: { mode: "glass" },
    },
    "glass-off": {
      note: "Liquid Glass off (the default since cmux#46104): every level draws the opaque surface and its hairline.",
      props: { mode: "off" },
    },
    "reduce-transparency": {
      note: "Reduce Transparency: the opaque surface and the hairline, as with Liquid Glass off.",
      props: { mode: "reduce" },
    },
    "hover-input": {
      note: "The chat input box, tooltips, a link's hover card and the header's tool preview over a transcript (Leo, 2026-11-20: more glass on the input box and on every hover surface).",
      props: { mode: "glass", scene: "hover-input" },
    },
    "hover-input-reduce": {
      note: "The same under Reduce Transparency: every surface opaque, no blur.",
      props: { mode: "reduce", scene: "hover-input" },
    },
  },
});
