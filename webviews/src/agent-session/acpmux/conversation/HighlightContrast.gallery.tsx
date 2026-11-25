// l10n-allow-file: gallery fixtures (sample transcript text), not shipped UI.
// HIGHLIGHT-CONTRAST (ui/highlightContrast.ts): Find in Chat and a text selection over every surface a
// chat draws text on (the transcript, a prompt's bubble, a tool card, a code block, a glass card),
// under Find's bar, with a timestamp's tooltip just under the bar. The variants compare how far a
// highlight moves from its theme color to stand out from its surface; `fit` is what ships. Open each
// in light and dark (the gallery's appearance control). Leo 2026-11-07: "this Command F thing ... the
// inner highlight ... needs to be a bit more, like distinguishable. And then two, we don't want it to
// be coverable by other sorts of things ... sometimes there's, like, low contrast on the highlight."
import { useLayoutEffect, useRef, useState, type CSSProperties } from "react";
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { assistant, user } from "../../../gallery/fixtures/acpmux";
import { Tooltip } from "../../../ui/Tooltip";
import { paintAdaptiveFind, clearAdaptiveFind } from "../../../ui/findPaint";
import {
  fitHighlightOn,
  highlightCss,
  HIGHLIGHT_FLOORS,
  inkOf,
  resolveCssColor,
  surfaceUnder,
  type HighlightFloor,
} from "../../../ui/highlightContrast";
import { SELECTION_BASE } from "../../../ui/adaptiveSelection";
import { ChatFindBar } from "./ChatFindBar";
import { useChatFind } from "./chatFind";

type Strategy = "theme-colors" | "fit-soft" | "fit" | "fit-strong";
type Floors = { selection: HighlightFloor; match: HighlightFloor; current: HighlightFloor };

const NONE: HighlightFloor = { surface: 0, ink: 0 };
const STRATEGIES: Record<Strategy, Floors> = {
  // The theme's colors as they are (before): the selection and matches never move.
  "theme-colors": { selection: NONE, match: NONE, current: NONE },
  "fit-soft": {
    selection: { surface: 1.2, ink: 4.5 },
    match: { surface: 1.2, ink: 4.5 },
    current: { surface: 2, ink: 4.5 },
  },
  fit: {
    selection: HIGHLIGHT_FLOORS.selection,
    match: HIGHLIGHT_FLOORS.findMatch,
    current: HIGHLIGHT_FLOORS.findCurrent,
  },
  "fit-strong": {
    selection: { surface: 1.6, ink: 4.5 },
    match: { surface: 1.5, ink: 4.5 },
    current: { surface: 4.5, ink: 4.5 },
  },
};

const QUERY = "library";
const rows = [
  user("Which library parses the config?", 6),
  assistant("The config library is read once at startup; the library cache keeps it.", 5),
];
const CHAT_FIND_COLORS = {
  match: "color-mix(in srgb, var(--agent-highlight, #f5c542) 40%, transparent)",
  current: "var(--agent-highlight, #f5c542)",
  currentInk: "var(--agent-highlight-text, #1d1d1f)",
};

/** Every occurrence of `needle` in the text under `root`. */
function occurrences(root: Element, needle: string): Range[] {
  const ranges: Range[] = [];
  const walker = root.ownerDocument.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const text = (node.textContent ?? "").toLowerCase();
    for (let at = text.indexOf(needle); at >= 0; at = text.indexOf(needle, at + needle.length)) {
      const range = root.ownerDocument.createRange();
      range.setStart(node, at);
      range.setEnd(node, at + needle.length);
      ranges.push(range);
    }
  }
  return ranges;
}

function Board({ strategy }: { strategy: Strategy }) {
  const find = useChatFind(rows);
  const board = useRef<HTMLDivElement>(null);
  const [selectionFill, setSelectionFill] = useState<string>();
  const { show } = find;
  useLayoutEffect(() => show(QUERY), [show]);
  useLayoutEffect(() => {
    const root = board.current;
    if (!root) return;
    const doc = root.ownerDocument;
    const floors = STRATEGIES[strategy];
    const ranges = occurrences(root.querySelector("[data-board-text]")!, QUERY);
    // The current match sits in the prompt's bubble, as in the screenshot.
    const current = ranges[1];
    paintAdaptiveFind(doc, "gallery-contrast", CHAT_FIND_COLORS, ranges, current ? [current] : [], [], floors);
    // The selection's fill for this strategy, fit to the bubble; the variant's play selects the words
    // after the find field has taken focus (and the selection with it).
    const selected = root.querySelector("[data-board-selected]")!;
    const base = resolveCssColor(doc, SELECTION_BASE);
    if (base) {
      const surface = surfaceUnder(selected.firstChild);
      setSelectionFill(
        highlightCss(fitHighlightOn(base, [surface], inkOf(selected.firstChild, surface), floors.selection).fill),
      );
    }
    return () => clearAdaptiveFind("gallery-contrast");
  }, [strategy]);
  return (
    <div
      ref={board}
      className="acpmux-shell hc-board"
      style={
        {
          position: "relative",
          height: "100%",
          overflow: "auto",
          // A block that scrolls, as the pane's `.acpmux-scroll` is: the shell's flex row would shrink
          // the find bar's zero-height layer to no width and push the pill off the left edge.
          display: "block",
          "--hc-selection": selectionFill,
          // No Session Info beside the chat here (SessionInfo.tsx sets it in the pane).
          "--acpmux-session-info-clear": "0px",
        } as CSSProperties
      }
    >
      {/* The board's own selection rule, so a variant shows its strategy whatever the page's fit sets. */}
      <style>{`.hc-board ::selection { background-color: var(--hc-selection) !important; }`}</style>
      <ChatFindBar find={find} />
      <div
        data-board-text
        // The transcript's words are content a person copies (desktop.css `.selectable`).
        className="selectable"
        style={{
          display: "grid",
          gap: "var(--ds-space-3)",
          padding: "var(--ds-space-56) var(--ds-space-5) var(--ds-space-5)",
          fontSize: "var(--text-content)",
          lineHeight: 1.5,
        }}
      >
        <div style={{ display: "flex", justifyContent: "flex-end", alignItems: "center", gap: 8 }}>
          <Tooltip label="Nov 7, 2026, 12:05 AM">
            <span className="hc-time" style={{ color: "var(--agent-muted)", fontSize: "var(--text-detail)" }}>
              12:05 AM
            </span>
          </Tooltip>
        </div>
        <p style={{ margin: 0, color: "var(--cv-text)" }}>
          The config library is read once at startup; the library cache keeps it for every later read.
        </p>
        <div style={{ display: "flex", justifyContent: "flex-end" }}>
          <div className="cv-user__bubble ui-glass">
            Which library parses the config? <span data-board-selected>Check the retry path too.</span>
          </div>
        </div>
        <div
          style={{
            padding: "var(--ds-space-2) var(--ds-space-3)",
            borderRadius: "var(--ds-radius-xl)",
            background: "var(--cv-card-fill)",
            color: "var(--cv-text-muted)",
          }}
        >
          Read src/config/library.ts · 48 lines
        </div>
        <pre
          className="cv-codeblock"
          style={{ margin: 0, padding: "var(--ds-space-2) var(--ds-space-3)", background: "var(--cv-codeblock-bg)" }}
        >
          <code>{`import { load } from "./library";\nconst config = load(); // library cache`}</code>
        </pre>
        <div
          className="ui-card ui-glass"
          style={{ padding: "var(--ds-space-2) var(--ds-space-3)", borderRadius: "var(--ds-radius-xl)" }}
        >
          A hover card over the transcript: the library it names.
        </div>
      </div>
    </div>
  );
}

const selectBubbleWords = async (ctx: PlayContext) => {
  await ctx.selectText({ selector: "[data-board-selected]" });
};
const variant = (strategy: Strategy, note: string) => ({ note, props: { strategy }, play: selectBubbleWords });

export default componentEntry<{ strategy: Strategy }>({
  id: "agent-pane.highlight-contrast",
  title: "Find and selection contrast",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/conversation/ChatFindBar.tsx#ChatFindBar", "ui/Tooltip.tsx#Tooltip"],
  load: async () => Board,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  widths: { normal: 640 },
  variants: {
    "theme-colors": variant(
      "theme-colors",
      "Before: the theme's selection and find colors on every surface as they are.",
    ),
    "fit-soft": variant("fit-soft", "Each highlight moves only to a small step from its surface (1.2:1, current 2:1)."),
    fit: variant("fit", "Ships: selection and matches 1.3:1 from their surface, the current match 3:1, text AA."),
    "fit-strong": variant("fit-strong", "The strongest: selection 1.6:1, matches 1.5:1, the current match 4.5:1."),
    "find-bar-layer": {
      note: "A timestamp's tooltip just under the find bar opens below its row, never over the bar.",
      props: { strategy: "fit" },
      play: async (ctx) => {
        await ctx.hover({ selector: ".hc-time" });
        await ctx.waitFor(() => ctx.document.querySelector(".ui-tooltip"));
      },
    },
  },
});
