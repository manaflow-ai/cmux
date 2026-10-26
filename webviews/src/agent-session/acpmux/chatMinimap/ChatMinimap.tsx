// The VS Code Minimap (Leo, 2026-10-25: "minimap? i dont see any command for the vscode minimap"): a
// small picture of the whole chat at its right edge, off by default (agentPane.display.vscodeMinimap).
// One <canvas> (paint.ts), never a node per row; a scroll only moves the view box, by transform. It
// draws when the rows change (at most every REDRAW_MS, once a scroll rests), on a new size or theme,
// in a task posted after a frame. While a reply streams it is frozen (Leo, 2026-10-26: "Just don't have
// it do anything when a reply is streaming"): the rows above the reply draw once, the reply's place is
// a placeholder with a shimmer (chatMinimap.css), and it draws once when the reply ends. The box then
// moves only for the person's own scrolling, never for the transcript following the reply. Every listener, observer and timer goes on unmount.
import React, { memo, useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import { transcriptColumn, type AcpmuxRow, type ConversationLayout } from "../model";
import { useT } from "../i18n";
import { useChatDisplay, useChatMinimap } from "../chatDisplay";
import { chatColumnOf, useChatWidth } from "../chatWidth";
import type { RowsChange } from "../threadMinimap/model";
import { stopScroll } from "../threadMinimap/scrollMotion";
import { THREAD_PADDING_TOP } from "../threadMinimap/model";
import { experimentArm } from "../../../experiments/experiment";
import { chatMinimapPlaceholder } from "./placeholder.experiment";
import {
  firstChangedRow,
  MINIMAP_BOTTOM,
  MINIMAP_EDGE,
  MINIMAP_TOP,
  MINIMAP_WIDTH,
  minimapScale,
  minimapView,
  paintMinimap,
  streamingRow,
  type MinimapColors,
} from "./paint";
import "./chatMinimap.css";

/// While the rows keep changing, the picture follows at most this often.
export const REDRAW_MS = 250;
/// A scroll rests this long before rows measured while it moved draw (at most SCROLL_MAX_WAIT_MS late).
const SCROLL_REST_MS = 150;
const SCROLL_MAX_WAIT_MS = 1000;
/// The transcript follows the reply when it sits this close to its end (App.tsx keeps 4 px).
const LATEST_PX = 8;
/// The placeholder is never thinner than this, so a reply that just started still shows.
const MIN_PLACEHOLDER = 12;
const KEY_STEP = 40;
const PAGE_OVERLAP = 40;
/// A view too short for a useful map (a tiny pane) draws none.
const MIN_TRACK = 64;

type Props = {
  rows: readonly AcpmuxRow[];
  layout: ConversationLayout;
  scroller: React.RefObject<HTMLElement | null>;
  /// The transcript's view height (above the room under the last row).
  viewportHeight: number;
  /// Where the transcript's mask ends the view (the composer's top).
  foot: number;
  /// The pane's width, for the right gutter.
  width: number;
  scrolls: boolean;
  /// Where these rows first differ from the last render's (App.tsx rowsChange), if the transcript knows.
  change?: RowsChange;
};
type Source = { rows: readonly AcpmuxRow[]; layout: ConversationLayout };

/// The placeholder's look: the shimmer, except in the gallery, which compares the others. Only the
/// gallery sets an arm in globalThis.cmuxExperiments; a stored cmux.experiments override is ignored.
export const placeholderLook = () => experimentArm(chatMinimapPlaceholder, { stored: {} });

/// Draws nothing, and reads no row, unless the setting is on; the rows are tracked only then.
export function ChatMinimap(props: Props) {
  return useChatMinimap() ? <ChatMinimapOn {...props} /> : null;
}

/// The setting is on: draws when the right gutter has room for it.
function ChatMinimapOn(props: Props) {
  const track = Math.floor(props.foot - MINIMAP_TOP - MINIMAP_BOTTOM);
  // The right gutter of the column the chat really draws (Text Width, Full Width): none, no minimap.
  const column = chatColumnOf(useChatWidth(), useChatDisplay());
  const room = transcriptColumn(props.width, column).inset >= MINIMAP_WIDTH + 2 * MINIMAP_EDGE;
  // The rows reach the map through a ref: a token renders nothing in it.
  const source = useRef<Source>({ rows: props.rows, layout: props.layout });
  source.current = { rows: props.rows, layout: props.layout };
  const changed = useRef<(() => void) | undefined>(undefined);
  const { rows, layout } = props;
  useEffect(() => changed.current?.(), [rows, layout]);
  const found = useRef<{ rows: readonly AcpmuxRow[]; index: number } | undefined>(undefined);
  const streaming = streamingRow(rows, found.current, props.change);
  found.current = { rows, index: streaming };
  if (!room || !props.scrolls || track < MIN_TRACK) return null;
  return (
    <Minimap
      source={source}
      changed={changed}
      streaming={streaming}
      scroller={props.scroller}
      viewportHeight={props.viewportHeight}
      track={track}
    />
  );
}

/// The theme's inks: the canvas's computed colors, which chatMinimap.css maps to the chat's tokens.
function readColors(canvas: HTMLCanvasElement): MinimapColors {
  const style = getComputedStyle(canvas);
  return { reply: style.color, prompt: style.borderTopColor, tool: style.borderBottomColor }; // prettier-ignore
}

const Minimap = memo(function Minimap({
  source,
  changed,
  streaming,
  scroller,
  viewportHeight,
  track,
}: {
  source: React.RefObject<Source>;
  changed: React.RefObject<(() => void) | undefined>;
  streaming: number;
  scroller: React.RefObject<HTMLElement | null>;
  viewportHeight: number;
  track: number;
}) {
  const t = useT();
  const canvas = useRef<HTMLCanvasElement>(null);
  const view = useRef<HTMLDivElement>(null);
  const control = useRef<HTMLDivElement>(null);
  // The scrollbar controls the transcript: its id, given here when it has none.
  const ownId = useId();
  const [controls, setControls] = useState<string | undefined>(undefined);
  // A passive effect: the scroller is this component's parent, whose ref is attached after this
  // child's layout effects run.
  useEffect(() => {
    const node = scroller.current;
    if (!node) return;
    const given = !node.id;
    if (given) node.id = ownId;
    setControls(node.id);
    return () => {
      if (given && node.id === ownId) node.removeAttribute("id");
    };
  }, [scroller, ownId]);
  const [dragging, setDragging] = useState(false);
  /// The placeholder over the streaming reply: its place on the map, set once per stream.
  const [look] = useState(placeholderLook);
  const [hold, setHold] = useState<{ top: number; height: number } | undefined>(undefined);
  const live = useRef({ viewportHeight, track, streaming });
  live.current = { viewportHeight, track, streaming };
  // What is drawn; `atLatest`: while a reply streams, whether the view box was last put at the end.
  // prettier-ignore
  const drawn = useRef({
    scale: 0, draws: 0, at: -Infinity, colors: undefined as MinimapColors | undefined,
    painted: undefined as Source | undefined, boxHeight: "", transform: "", scrolledAt: -Infinity, atLatest: false, box: { top: 0, height: 0 }, boxScrolled: false,
  });
  type Timer = ReturnType<typeof setTimeout> | 0;
  const pending = useRef({ frame: 0, timer: 0 as Timer, post: 0 as Timer, sized: false });

  // The view box follows the scroll by transform alone, written only when its rounded value changes.
  const [placeView] = useState(() => () => {
    const node = scroller.current;
    const box = view.current;
    if (!node || !box) return;
    const { viewportHeight: height, track: rail } = live.current;
    const top = node.scrollTop;
    const at = minimapView(top, height, drawn.current.scale, rail);
    // Where the box is drawn, which a press hit-tests against (it stays put while a reply streams).
    drawn.current.box = { top: Math.round(at.top * 4) / 4, height: Math.round(at.height * 4) / 4 };
    const transform = `translateY(${drawn.current.box.top}px)`;
    if (drawn.current.transform !== transform) box.style.transform = drawn.current.transform = transform;
    const boxHeight = `${drawn.current.box.height}px`;
    if (drawn.current.boxHeight !== boxHeight) box.style.height = drawn.current.boxHeight = boxHeight;
    placeValue();
  });
  /// The control's value: the share of the scroller's own range scrolled, written when it changes.
  const [placeValue] = useState(() => () => {
    const node = scroller.current;
    const owner = control.current;
    if (!node || !owner) return;
    const range = node.scrollHeight - node.clientHeight;
    const now = String(range > 0 ? Math.round((100 * Math.min(range, Math.max(0, node.scrollTop))) / range) : 0);
    if (owner.getAttribute("aria-valuenow") !== now) owner.setAttribute("aria-valuenow", now);
  });
  /// While a reply streams, the rows' changes move nothing on the map, but the range grows under the
  /// reader: the value follows in the box's own frame (set by the scroll effect below).
  const valueFrame = useRef<() => void>(() => {});

  const [draw] = useState(() => () => {
    const state = pending.current;
    state.post = 0;
    const node = canvas.current;
    if (!node) return;
    const record = drawn.current;
    const now = performance.now();
    const resting = now - record.scrolledAt;
    if (!state.sized && resting < SCROLL_REST_MS && now - record.at < SCROLL_MAX_WAIT_MS) {
      state.timer ||= setTimeout(() => {
        state.timer = 0;
        frameThenDraw();
      }, SCROLL_REST_MS - resting);
      return;
    }
    let whole = state.sized || !record.colors || !record.painted;
    state.sized = false;
    const height = live.current.track;
    const dpr = window.devicePixelRatio || 1;
    const pixelWidth = Math.round(MINIMAP_WIDTH * dpr);
    const pixelHeight = Math.round(height * dpr);
    // Resizing the backing store clears it: only when the size or the screen's scale changed.
    if (node.width !== pixelWidth || node.height !== pixelHeight) {
      node.width = pixelWidth;
      node.height = pixelHeight;
      whole = true;
    }
    // While a reply streams, the picture stops above it: the rows before it (one draw when it starts,
    // or a resize or new theme), never the reply as it grows.
    const frozen = live.current.streaming;
    const all = frozen >= 0 ? source.current.rows.slice(0, frozen) : source.current.rows;
    const placed = source.current.layout;
    const scale = minimapScale(placed.totalHeight, height);
    const before = record.painted;
    // Nothing changed: no paint.
    const same = !whole && before && scale === record.scale && all.length === before.rows.length;
    if (same && firstChangedRow(all, placed, before) >= all.length) return;
    record.colors ??= readColors(node);
    record.at = performance.now();
    record.draws += 1;
    const ctx = node.getContext("2d");
    if (ctx)
      paintMinimap(ctx, all, placed, {
        width: MINIMAP_WIDTH,
        height,
        dpr,
        scale,
        colors: record.colors,
      });
    record.scale = scale;
    record.painted = { rows: all, layout: placed };
    // The draws so far (tests, bench/thread-minimap-frame-cost.bench.ts).
    node.dataset.draws = String(record.draws);
    placeView();
  });
  /// The draw, after the next frame's rendering: a task posted from its requestAnimationFrame.
  const [frameThenDraw] = useState(() => () => {
    const state = pending.current;
    if (state.frame || state.post) return;
    state.frame = requestAnimationFrame(() => {
      state.frame = 0;
      state.post = setTimeout(draw, 0);
    });
  });
  /// Draws after the next frame; `soon` (rows or colors changed) waits until REDRAW_MS after the last draw.
  const [schedule] = useState(() => (soon: boolean) => {
    const state = pending.current;
    if (!soon) state.sized = true;
    if (state.frame || state.post) return;
    const wait = soon ? drawn.current.at + REDRAW_MS - performance.now() : 0;
    if (wait > 0) {
      state.timer ||= setTimeout(() => {
        state.timer = 0;
        frameThenDraw();
      }, wait);
      return;
    }
    if (state.timer) clearTimeout(state.timer);
    state.timer = 0;
    frameThenDraw();
  });

  // The rows changed (ChatMinimap's effect): a coalesced draw, unless a reply streams.
  useEffect(() => {
    changed.current = () => {
      if (live.current.streaming < 0) schedule(true);
      else valueFrame.current();
    };
    return () => {
      changed.current = undefined;
    };
  }, [changed, schedule]);
  // A new size: the next frame. The view box's height follows at once.
  useLayoutEffect(() => {
    placeView();
    schedule(false);
  }, [track, viewportHeight, placeView, schedule]);
  // A reply starts streaming: everything above it (the prompt that started it too) draws once as it
  // stands, and the reply's place on the map is the placeholder, sized now. It ends: one draw.
  useLayoutEffect(() => {
    if (streaming >= 0) {
      const { layout } = source.current;
      const scale = minimapScale(layout.totalHeight, track);
      const from = layout.tops[streaming] ?? layout.totalHeight;
      const top = Math.min(track - MIN_PLACEHOLDER, (from + THREAD_PADDING_TOP) * scale);
      const height = Math.min(track - top, Math.max(MIN_PLACEHOLDER, (layout.heights[streaming] ?? 0) * scale));
      setHold({ top, height });
    } else setHold(undefined);
    schedule(false);
  }, [streaming, track, schedule, source]);

  // A reply starts streaming: the box freezes where the view is now, after the transcript has placed
  // itself (a passive effect runs after its layout effects), so its own follow never moves the box.
  useEffect(() => {
    const node = scroller.current;
    if (streaming < 0 || !node) return;
    drawn.current.atLatest = node.scrollHeight - node.clientHeight - node.scrollTop <= LATEST_PX;
    placeView();
  }, [streaming, scroller, placeView]);

  useEffect(() => {
    const node = scroller.current;
    const state = pending.current;
    const recolor = () => {
      drawn.current.colors = undefined;
      schedule(true);
    };
    const resize = () => schedule(false);
    // A scroll only asks for one frame: the scroller is read and the view box written there, once a
    // frame however many scroll events came, and never inside the scroll event (no layout read there).
    const follow = () => {
      boxFrame = 0;
      const record = drawn.current;
      const scrolled = record.boxScrolled;
      record.boxScrolled = false;
      // Only the rows changed while a reply streams: the value alone.
      if (!scrolled) return placeValue();
      // While a reply streams, the transcript following it (its end, as the reply grows) leaves the box
      // where it was put when it reached the end; a scroll away from the end is the person's own, as
      // the transcript scrolls by itself only while it follows.
      if (live.current.streaming >= 0 && node) {
        const atLatest = node.scrollHeight - node.clientHeight - node.scrollTop <= LATEST_PX;
        if (atLatest && record.atLatest) return;
        record.atLatest = atLatest;
      } else record.atLatest = false;
      placeView();
    };
    let boxFrame = 0;
    const scrolled = () => {
      drawn.current.scrolledAt = performance.now();
      drawn.current.boxScrolled = true;
      boxFrame ||= requestAnimationFrame(follow);
    };
    valueFrame.current = () => void (boxFrame ||= requestAnimationFrame(follow));
    const theme = new MutationObserver(recolor);
    theme.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["class", "style", "data-theme"],
    });
    window.addEventListener("resize", resize);
    node?.addEventListener("scroll", scrolled, { passive: true });
    return () => {
      theme.disconnect();
      window.removeEventListener("resize", resize);
      node?.removeEventListener("scroll", scrolled);
      if (state.frame) cancelAnimationFrame(state.frame);
      if (boxFrame) cancelAnimationFrame(boxFrame);
      valueFrame.current = () => {};
      if (state.timer) clearTimeout(state.timer);
      if (state.post) clearTimeout(state.post);
      state.frame = 0;
      state.timer = 0;
      state.post = 0;
    };
  }, [scroller, placeView, placeValue, schedule]);

  /// Scrolls so map point `y` is at the view's middle, at once (VS Code's minimap jumps, then drags).
  const seek = (y: number, grab = live.current.viewportHeight / 2) => {
    const node = scroller.current;
    const scale = drawn.current.scale;
    if (!node || scale <= 0) return;
    stopScroll(node);
    node.scrollTop = Math.max(0, y / scale - grab);
  };
  const press = useRef<{ pointer: number; grab: number } | undefined>(undefined);
  const release = () => {
    press.current = undefined;
    setDragging(false);
  };
  const local = (event: React.PointerEvent) => event.clientY - event.currentTarget.getBoundingClientRect().top;

  return (
    <div className="acpmux-chat-minimap">
      <div
        ref={control}
        className="acpmux-chat-minimap__track"
        role="scrollbar"
        tabIndex={0}
        aria-label={t("chatMinimap.label")}
        aria-orientation="vertical"
        aria-valuemin={0}
        aria-valuemax={100}
        // The share scrolled, as the view box shows it: written on focus and while focused (placeView).
        aria-valuenow={0}
        aria-controls={controls}
        onFocus={() => placeView()}
        data-dragging={dragging || undefined}
        style={{
          top: MINIMAP_TOP,
          right: MINIMAP_EDGE,
          width: MINIMAP_WIDTH,
          height: track,
        }}
        onPointerDown={(event) => {
          if (event.button !== 0) return;
          const node = scroller.current;
          const scale = drawn.current.scale;
          if (!node || scale <= 0) return;
          const y = local(event);
          const at = drawn.current.box;
          // On the box as drawn: drag it from where it was grabbed. Off it: jump there, then drag.
          const inside = y >= at.top && y <= at.top + at.height;
          const grab = inside ? (y - at.top) / scale : live.current.viewportHeight / 2;
          if (!inside) seek(y);
          press.current = { pointer: event.pointerId, grab };
          setDragging(true);
          try {
            event.currentTarget.setPointerCapture?.(event.pointerId);
          } catch {}
          event.preventDefault();
        }}
        onPointerMove={(event) => {
          const state = press.current;
          if (!state || state.pointer !== event.pointerId) return;
          seek(local(event), state.grab);
        }}
        onPointerUp={release}
        onPointerCancel={release}
        onKeyDown={(event) => {
          const node = scroller.current;
          if (!node) return;
          const page = Math.max(KEY_STEP, live.current.viewportHeight - PAGE_OVERLAP);
          const by: Record<string, number> = {
            ArrowUp: -KEY_STEP,
            ArrowDown: KEY_STEP,
            PageUp: -page,
            PageDown: page,
          };
          const delta =
            event.key === "Home" ? -node.scrollTop : event.key === "End" ? node.scrollHeight : by[event.key];
          if (delta === undefined) return;
          event.preventDefault();
          stopScroll(node);
          node.scrollTop = Math.max(0, node.scrollTop + delta);
        }}
      >
        <canvas
          ref={canvas}
          className="acpmux-chat-minimap__canvas"
          style={{ width: MINIMAP_WIDTH, height: track }}
          aria-hidden
        />
        {hold && (
          <div
            className="acpmux-chat-minimap__placeholder"
            data-look={look}
            style={{ top: hold.top, height: hold.height }}
            aria-hidden
          />
        )}
        <div ref={view} className="acpmux-chat-minimap__view" aria-hidden />
      </div>
    </div>
  );
});
