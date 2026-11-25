// l10n-allow-file: gallery fixtures (a sample chat page), not shipped UI.
// The UI inspector while picking (uiPointer/picker.ts), for Leo's ask (2026-11-08): "im also not
// entirely sure what it's used for" and "you should be able to just see maybe some sort of preview
// as you're going and hovering, and ... on your initial inspect element escapade as well". The real
// picker runs over a fixture chat page and is driven the way the native controller drives it:
// `start`, `highlight` at an element's centre, `inspectMenuTarget`, and the arrow keys.
// - `hint`: picking has started; the hint says what it is for and its keys.
// - `hover` (ships: the card above the outline), `density-*` and `placement-*`: the label's looks.
// - `edge-*`: the label at each viewport edge, flipped or clamped, never over the element.
// - `walk-parent`: Up walked from a word to its message.
// - `held`: the element held right after Inspect Element, labelled at once.
import React from "react";
import { componentEntry } from "../../../gallery/format";
import { UiPointerStage, type UiPointerStageProps as Props, type UiPointerStep as Step } from "./UiPointerStage";

const page: React.CSSProperties = {
  position: "fixed",
  inset: 0,
  display: "flex",
  flexDirection: "column",
  gap: 12,
  padding: 0,
  background: "var(--agent-page-bg)",
  color: "var(--agent-text)",
  fontFamily: "var(--font-ui)",
  fontSize: "var(--text-body)",
};
const bar: React.CSSProperties = {
  display: "flex",
  justifyContent: "space-between",
  alignItems: "center",
  height: 32,
  padding: "0 0 0 0",
  borderBottom: "1px solid var(--agent-border)",
};
const bubble: React.CSSProperties = {
  alignSelf: "flex-end",
  maxWidth: "70%",
  marginInline: 16,
  padding: "8px 12px",
  borderRadius: 12,
  background: "var(--agent-soft)",
};

function Fixture() {
  return (
    <div style={page}>
      <header data-cmux-component="ChatHeader" data-ui-pointer-target="top" style={bar}>
        <span data-ui-pointer-target="left" style={{ padding: "4px 8px" }}>
          Fix the login form
        </span>
        <button type="button" data-ui-pointer-target="right" className="ghost-btn" style={{ marginInlineEnd: 0 }}>
          Share
        </button>
      </header>
      <div data-cmux-component="UserMessage" style={bubble} data-ui-pointer-target="bubble">
        Why does the <strong data-ui-pointer-target="word">Sign in</strong> button jump when the error shows?
      </div>
      <p data-cmux-component="AssistantMessage" style={{ margin: "0 16px" }} data-ui-pointer-target="reply">
        The error row is inserted above the button, so the button moves down by the row's height.
      </p>
      <div style={{ flex: 1 }} />
      <footer
        data-cmux-component="Composer"
        data-ui-pointer-target="bottom"
        style={{ padding: "8px 16px", borderTop: "1px solid var(--agent-border)", color: "var(--agent-muted)" }}
      >
        Ask for follow-up changes
      </footer>
    </div>
  );
}

function PickerStage(props: Props) {
  return (
    <UiPointerStage {...props}>
      <Fixture />
    </UiPointerStage>
  );
}

const hover = (target: string, keys?: string[]): Step => ({ kind: "hover", target, keys });

export default componentEntry<Props>({
  id: "agent-pane.ui-inspector",
  title: "UI inspector picking",
  area: "Agent pane",
  pane: true,
  height: 420,
  widths: { narrow: 320, normal: 640 },
  // The picker is DOM, not React: the stage runs the real picker (picker.ts, overlay.ts, labelModel.ts).
  covers: ["agent-session/acpmux/uiPointer/UiPointerStage.tsx#UiPointerStage"],
  keywords: ["inspect element", "pointer", "picker", "outline"],
  styles: () => import("./uiPointer.css"),
  load: () => Promise.resolve(PickerStage),
  variants: {
    hint: {
      note: "Picking started, nothing under the pointer yet: the hint and its keys.",
      props: { step: { kind: "start" } },
    },
    hover: {
      note: "Ships: the card (name, selector, size; text; colour, font, display) above the outline, flipping below.",
      props: { step: hover("reply") },
    },
    "density-compact": {
      note: "One line: the name and the size.",
      props: { step: hover("reply"), density: "compact" },
    },
    "density-standard": {
      note: "Two lines: the name, selector and size; the text.",
      props: { step: hover("reply"), density: "standard" },
    },
    "placement-below": {
      note: "Below the outline first, flipping above.",
      props: { step: hover("reply"), placement: "below" },
    },
    "placement-side": {
      note: "Beside the outline first (right, then left), then above or below.",
      props: { step: hover("bubble"), placement: "side" },
    },
    "placement-inside": {
      note: "Inside the outline's corner: always close, but it covers the element it names.",
      props: { step: hover("reply"), placement: "inside" },
    },
    "edge-top": { note: "An element at the top edge: the label flips below.", props: { step: hover("top") } },
    "edge-left": { note: "At the left edge: the label starts at the edge inset.", props: { step: hover("left") } },
    "edge-right": { note: "At the right edge: the label is clamped inside.", props: { step: hover("right") } },
    "edge-bottom": {
      note: "At the bottom edge: the label sits above; the hint stays at the top.",
      props: { step: hover("bottom") },
    },
    "walk-parent": {
      note: "Up from the bold words walked to their message; Down returns, Left and Right step siblings.",
      props: { step: hover("word", ["ArrowUp"]) },
    },
    held: {
      note: "Right after Inspect Element: the right-clicked element is held and labelled at once.",
      props: { step: { kind: "held", target: "bubble" } },
    },
  },
});
