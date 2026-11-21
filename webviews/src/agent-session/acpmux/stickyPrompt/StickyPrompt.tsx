// l10n-allow-file: PROTOTYPE (gallery only, experiment default off); strings move to the catalog when an arm ships.
// The sticky prompt (stickyPrompt.experiment.ts): the prompt the view is in, pinned at the top while
// its answer scrolls, a jump to the last prompt, and Option-Up/Down between prompts.
// Cost per scroll: one binary search (stickyPromptModel.ts `stickyState`); the prompt indexes are
// rebuilt only when rows change, appends incrementally. No observers per row.
import React, { useEffect, useRef, useState } from "react";
import { ArrowDown, ChevronDown } from "../conversation/icons";
import type { AcpmuxRow } from "../model";
import { promptIndexes, stickyState, type PromptScanState } from "./stickyPromptModel";
import type { StickyPromptArm } from "./stickyPrompt.experiment";
import "./stickyPrompt.css";

/// The pinned header's own height for the push (one line plus padding), px.
const HEADER_PX = 34;
/// How far under the view's top a prompt's row counts as the one being read (a jump puts it 12 px under).
const PROBE_PX = 16;

export type StickyPromptProps = {
  arm: StickyPromptArm;
  rows: readonly AcpmuxRow[];
  geometry: {
    topAt: (index: number) => number;
    heightAt: (index: number) => number;
  };
  totalHeight: number;
  /// The view's top in layout coordinates, and its height.
  viewTop: number;
  viewHeight: number;
  /// Where the top zone starts (under the header), px from the stage top.
  zoneTop: number;
  /// Room over the bottom stack, for the bottom-center pill.
  lift: number;
  /// Puts row `index`'s top just under the top zone.
  onJump: (index: number) => void;
};

const firstLine = (text: string | undefined) => (text ?? "").trim().split("\n")[0] ?? "";

export function StickyPrompt(props: StickyPromptProps) {
  const { arm, rows, geometry, viewTop, viewHeight, zoneTop, lift, onJump, totalHeight } = props;
  const scan = useRef<PromptScanState>({ length: 0, indexes: [] });
  scan.current = promptIndexes(rows, scan.current);
  const indexes = scan.current.indexes;
  // Probed a little under the view's top: a prompt jumped to sits PROBE_PX under it and is "here".
  const state = stickyState(indexes, geometry, viewTop + PROBE_PX, viewHeight);
  const [open, setOpen] = useState(false);
  const pinnedIndex = state.pinned ? state.index : -1;
  // Another prompt pinned: the expanded line closes.
  useEffect(() => setOpen(false), [pinnedIndex]);

  // Option-Up / Option-Down: previous and next prompt, from where the view is. Read through a ref so
  // the listener is added once.
  const live = useRef({ indexes, state, viewTop, geometry, onJump });
  live.current = { indexes, state, viewTop, geometry, onJump };
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (!event.altKey || event.metaKey || event.ctrlKey || event.defaultPrevented) return;
      if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
      const target = event.target as HTMLElement | null;
      // A field with text keeps its keys (caret moves); an empty composer gives them to the chat.
      if (
        target?.closest?.("input, textarea, [contenteditable='true']") &&
        (target.textContent || (target as HTMLTextAreaElement).value)
      )
        return;
      const { indexes: all, state: at, viewTop: top, geometry: geo, onJump: jump } = live.current;
      if (all.length === 0) return;
      event.preventDefault();
      let slot: number;
      if (event.key === "ArrowUp") {
        // At a prompt's own top already: the one before; else this turn's prompt.
        const here = at.slot >= 0 && geo.topAt(all[at.slot]!) < top - 4 ? at.slot : at.slot - 1;
        slot = Math.max(0, here);
      } else slot = Math.min(all.length - 1, at.slot + 1);
      jump(all[slot]!);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  if (arm === "off" || indexes.length === 0) return null;
  const row = state.index >= 0 ? rows[state.index] : undefined;
  const shown = state.pinned && row !== undefined;
  const text = row?.text ?? "";
  const turn = state.slot + 1;

  if (arm === "chip" || arm === "line" || arm === "fade") {
    // Pushed out by the next prompt's row as it arrives under the header (section-header style).
    const push = Math.min(0, state.room - HEADER_PX - 8);
    const fade =
      arm === "fade"
        ? Math.min(1, Math.max(0, (viewTop - (geometry.topAt(state.index) + geometry.heightAt(state.index))) / 48)) *
          Math.min(1, Math.max(0, (state.room - 8) / HEADER_PX))
        : 1;
    return (
      <div
        className="acpmux-sticky-prompt"
        data-arm={arm}
        data-shown={shown ? "" : undefined}
        data-open={open ? "" : undefined}
        style={
          {
            top: zoneTop,
            "--sticky-push": `${push}px`,
            "--sticky-fade": fade,
          } as React.CSSProperties
        }
        inert={!shown}
      >
        {arm === "chip" && (
          <button
            type="button"
            className="ui-glass acpmux-sticky-prompt__chip"
            title={`${text}\n\nClick: back to this prompt`}
            onClick={() => onJump(state.index)}
          >
            <ArrowDown size={12} style={{ transform: "rotate(180deg)" }} />
            <span className="acpmux-sticky-prompt__text">{firstLine(text)}</span>
          </button>
        )}
        {arm === "line" && (
          <div className="ui-glass acpmux-sticky-prompt__line">
            <button
              type="button"
              className="acpmux-sticky-prompt__line-body"
              aria-expanded={open}
              onClick={() => (open ? onJump(state.index) : setOpen(true))}
              title={open ? "Jump to this prompt" : "Show the whole prompt"}
            >
              <span className="acpmux-sticky-prompt__turn">#{turn}</span>
              <span className="acpmux-sticky-prompt__text">{open ? text : firstLine(text)}</span>
            </button>
            <button
              type="button"
              className="acpmux-sticky-prompt__toggle"
              aria-label={open ? "Collapse" : "Expand"}
              onClick={() => setOpen(!open)}
            >
              <ChevronDown size={12} style={{ transform: open ? "rotate(180deg)" : undefined }} />
            </button>
          </div>
        )}
        {arm === "fade" && (
          <button type="button" className="acpmux-sticky-prompt__flat" onClick={() => onJump(state.index)}>
            <span className="acpmux-sticky-prompt__caret" aria-hidden="true">
              &gt;
            </span>
            <span className="acpmux-sticky-prompt__text">{firstLine(text)}</span>
          </button>
        )}
      </div>
    );
  }

  if (arm === "jump") {
    const last = indexes[indexes.length - 1]!;
    // Shown once the last prompt's row is out of view (above or below).
    const lastTop = geometry.topAt(last) - viewTop;
    const away = lastTop < -geometry.heightAt(last) || lastTop > viewHeight;
    return (
      <div className="acpmux-sticky-prompt-jump" style={{ bottom: lift + 56 }}>
        <button
          type="button"
          className="ui-glass acpmux-sticky-prompt-jump__pill"
          data-shown={away ? "" : undefined}
          inert={!away}
          onClick={() => onJump(last)}
          title={firstLine(rows[last]?.text)}
        >
          <ArrowDown
            size={12}
            style={{
              transform: lastTop > viewHeight ? undefined : "rotate(180deg)",
            }}
          />
          <span>Last prompt</span>
          <kbd>⌥↑</kbd>
        </button>
      </div>
    );
  }

  // rail: a tick per prompt on the track. Positions change only with rows or the total height;
  // the lit tick is the scroll's one state.
  return (
    <div className="acpmux-sticky-prompt-rail" style={{ top: zoneTop, bottom: lift }} aria-label="Prompts">
      {indexes.map((index, slot) => (
        <button
          key={rows[index]!.id}
          type="button"
          className="acpmux-sticky-prompt-rail__tick"
          data-current={slot === state.slot ? "" : undefined}
          style={{
            top: `${(geometry.topAt(index) / Math.max(1, totalHeight)) * 100}%`,
          }}
          title={firstLine(rows[index]!.text)}
          onClick={() => onJump(index)}
        />
      ))}
    </div>
  );
}

export const StickyPromptMemo = React.memo(StickyPrompt);
