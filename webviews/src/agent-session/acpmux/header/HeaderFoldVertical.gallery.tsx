// l10n-allow-file: gallery fixture data, not shipped UI.
// Leo, 2026-11-23: "the fucking buttons on the top right NEED to be done right, especially when things are at
// compressed width panes. we have an ellipsis. maybe it can go from horizontal to vertical with a sweet -ass
// animation, who knows." The prototype: at a narrow pane the quick actions fold from the row into a vertical column
// hanging under the "..."; each tool travels from its slot in the row to its slot in the column with a stagger
// (transform and opacity only, the page's motion tokens, no motion under Reduce Motion), and the "..." turns from
// horizontal to vertical. Folded closed, every button is on the header's one row; the column is an overlay, so
// nothing below moves. The slider drives the pane width; the checkbox opens the column; auto loops it.
import { useEffect, useRef, useState } from "react";
import type { CSSProperties } from "react";
import { componentEntry } from "../../../gallery/format";
import { HeaderIcon } from "./HeaderIcon";
import { ThreadTitle } from "./ThreadTitle";
import "./HeaderFoldVertical.gallery.css";

type Props = { width?: number; open?: boolean; auto?: boolean; controls?: boolean };

const PITCH = 26;
const FOLD_BELOW = 440;
/** The quick actions that fold; the panel toggle stays in the row. */
const FOLDING = [
  { icon: "diff.file", label: "Changes" },
  { icon: "terminal", label: "Terminal" },
  { icon: "browser", label: "Browser" },
  { icon: "folder", label: "Files" },
] as const;

function FoldVertical({ width: initialWidth = 800, open: initialOpen = false, auto = false, controls = true }: Props) {
  const [width, setWidth] = useState(initialWidth);
  const [open, setOpen] = useState(initialOpen);
  const [closing, setClosing] = useState(false);
  const pane = useRef<HTMLDivElement | null>(null);
  const folded = width < FOLD_BELOW;
  const shown = folded && open;

  const set = (next: boolean) => {
    setClosing(!next);
    setOpen(next);
  };

  useEffect(() => {
    if (!auto) return;
    const id = window.setInterval(() => set(!openRef.current), 1800);
    return () => window.clearInterval(id);
  }, [auto]);
  const openRef = useRef(open);
  openRef.current = open;

  useEffect(() => {
    if (!open) return;
    const away = (event: PointerEvent) => {
      if (!pane.current?.contains(event.target as Node)) set(false);
    };
    const escape = (event: KeyboardEvent) => event.key === "Escape" && set(false);
    document.addEventListener("pointerdown", away);
    document.addEventListener("keydown", escape);
    return () => {
      document.removeEventListener("pointerdown", away);
      document.removeEventListener("keydown", escape);
    };
  }, [open]);

  // Slots, counted from the "..." (k = 0) toward the left in the row; the column's from the "..." down.
  const tools = FOLDING.map((tool, index) => {
    const rowX = -(FOLDING.length - index) * PITCH;
    const columnY = (index + 1) * PITCH + 4 + 4;
    const state = !folded ? "row" : shown ? "column" : "stowed";
    const style = {
      "--i": index,
      "--n": FOLDING.length,
      "--x": state === "row" ? `${rowX + 0}px` : "0px",
      "--y": state === "column" ? `${columnY}px` : "0px",
      "--s": state === "stowed" ? 0.6 : 1,
      "--o": state === "stowed" ? 0 : 1,
    } as CSSProperties;
    return { ...tool, style, hidden: state === "stowed" };
  });
  // The panel toggle sits left of the row's tools while unfolded, and next to the "..." when folded.
  const panelX = folded ? -PITCH : -(FOLDING.length + 1) * PITCH;
  const reserve = (folded ? 2 : FOLDING.length + 2) * PITCH + 8 + 8;

  return (
    <div className="hf-stage">
      <div className="hf-pane" ref={pane} style={{ width }}>
        <div
          className="hf-header acpmux-shell"
          data-fold={folded ? (shown ? "column" : "closed") : "row"}
          style={{ "--hf-reserve": `${reserve}px`, "--hf-count": FOLDING.length } as CSSProperties}
        >
          <div className="hf-title">
            <ThreadTitle title="Remove send-scroll" onRename={() => undefined} />
          </div>
          <div className="acpmux-header-tools hf-tools" role="toolbar" aria-label="Chat tools">
            <span
              className="hf-card"
              aria-hidden="true"
              style={{ "--card-s": shown ? 1 : 0.2, "--card-o": shown ? 1 : 0 } as CSSProperties}
            />
            <button
              type="button"
              className="acpmux-header-tool hf-tool"
              aria-label="Session Info"
              style={{ "--x": `${panelX}px`, "--i": 0 } as CSSProperties}
            >
              <HeaderIcon name="view.list" />
            </button>
            {tools.map((tool) => (
              <button
                key={tool.label}
                type="button"
                className="acpmux-header-tool hf-tool"
                aria-label={tool.label}
                aria-hidden={tool.hidden || undefined}
                tabIndex={tool.hidden ? -1 : 0}
                data-hidden={tool.hidden ? "" : undefined}
                data-closing={closing ? "" : undefined}
                style={tool.style}
              >
                <HeaderIcon name={tool.icon} />
              </button>
            ))}
            <button
              type="button"
              className="acpmux-header-tool acpmux-header-more hf-tool hf-more"
              aria-label="Chat actions"
              aria-expanded={folded ? shown : undefined}
              data-popup-open={shown ? "" : undefined}
              style={{ "--turn": shown ? "90deg" : "0deg" } as CSSProperties}
              onClick={() => folded && set(!open)}
            >
              <HeaderIcon name="action.more" />
            </button>
          </div>
        </div>
      </div>
      {controls && (
        <div className="hf-controls">
          <label>
            pane width {width}px{" "}
            <input
              aria-label="pane width"
              type="range"
              min={240}
              max={800}
              step={4}
              value={width}
              onChange={(event) => setWidth(Number(event.target.value))}
            />
          </label>
          <label>
            <input aria-label="open" type="checkbox" checked={open} onChange={(event) => set(event.target.checked)} />{" "}
            open
          </label>
        </div>
      )}
      <div className="hf-note">
        {folded
          ? shown
            ? "Folded, open: the tools hang in a column under the vertical ..."
            : "Folded, closed: everything on the one row; tools stowed under the ..."
          : `Row (${FOLD_BELOW}px and wider): every quick action in the row`}
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.header-fold-vertical",
  title: "Header tools fold into a vertical column (prototype)",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 400, normal: 560, wide: 860 },
  covers: ["agent-session/acpmux/header/HeaderIcon.tsx#HeaderIcon"],
  load: async () => FoldVertical,
  styles: () => Promise.all([import("../styles.css"), import("../../../ui/popupSurface.css"), import("./header.css")]),
  variants: {
    wide: {
      props: { width: 560, controls: true },
      note: "560px: every quick action in the row; drag the slider under 440 to watch them fold.",
    },
    "narrow-closed": {
      props: { width: 320, controls: false },
      note: "320px folded closed: the tools stowed under the ..., all on the one row, never lower.",
    },
    "narrow-open": {
      props: { width: 320, open: true, controls: false },
      note: "320px open: the ... turned vertical and the tools in a column under it, an overlay over the page.",
    },
    loop: {
      props: { width: 320, auto: true, controls: true },
      note: "Folds and unfolds on a loop at 320px; Reduce Motion makes it instant.",
    },
  },
});
