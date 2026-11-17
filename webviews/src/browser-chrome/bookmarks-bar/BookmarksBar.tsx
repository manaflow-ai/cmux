// The bookmarks bar under a browser tab's toolbar (design/browser-chrome.md "Bookmarks bar"), the
// native BookmarksBarView's look and behavior: the bar root's items left to right (icon and title,
// a gray hover fill, no accent), folders as native menus, a chevron for what does not fit, Other
// Bookmarks at the trailing end when it has anything. Drag an item to reorder it; drop a link to
// bookmark it there. Only the items that fit are rendered: the bar's cost follows its width, not
// the number of bookmarks. State lives in `BookmarksBarStore`; this file renders it.
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type DragEvent, type MouseEvent } from "react";
import { displayTitle, iconKey } from "../../pages/bookmarks/model";
import { FolderGlyph, GlobeGlyph } from "../../pages/bookmarks/glyphs";
import type { Bookmark, Disposition } from "../../pages/bookmarks/types";
import {
  barHeight,
  COMPACT_METRICS,
  disposition,
  droppedTitle,
  droppedURL,
  indicatorX,
  insertionIndex,
  itemWidth,
  layoutBar,
  type BarMetrics,
} from "./model";
import type { Anchor, BarIcon, BarSnapshot, LaidOut } from "./store";

/** `parity` ships (today's native bar); `tonal` and `dense` are the looks it was picked against. */
export type BarLook = "parity" | "tonal" | "dense";

/** The drag's own type: a bar item's bookmark id (the native bar's `com.cmuxterm.bookmark-id`). */
export const DRAG_TYPE = "application/x-cmux-bookmark";

export interface BarWords {
  barTitle: string;
  more: string;
  emptyHint: string;
}

export interface BookmarksBarProps {
  snapshot: BarSnapshot;
  words: BarWords;
  /** The bar's width in CSS px when the host knows it (tests); otherwise the bar lays out from its
   * own rendered width, so the layout and the box it sits in always agree. */
  width?: number;
  look?: BarLook;
  /** A title's width in CSS px at the bar's font (a canvas in the page, a stand-in in tests). */
  measure?: (text: string) => number;
  onOpen: (node: Bookmark, disposition: Disposition) => void;
  onFolder: (node: Bookmark, anchor: Anchor) => void;
  /** The chevron: the items past the first `shown` are in its menu. */
  onOverflow: (shown: number, anchor: Anchor) => void;
  onOther: (anchor: Anchor) => void;
  onContextMenu: (bookmark: string | null, point: { x: number; y: number }) => void;
  onMove: (id: string, slot: number) => void;
  onDrop: (url: string, title: string, slot: number) => void;
  onIcons: (nodes: readonly Bookmark[]) => void;
  onLayout?: (laidOut: LaidOut) => void;
}

export function metricsFor(look: BarLook): BarMetrics {
  return look === "dense" ? { ...COMPACT_METRICS, padding: 6, gap: 0 } : COMPACT_METRICS;
}

/** A canvas measure at the font of `element` (the bar's title text). */
export function canvasMeasure(element: Element | null): (text: string) => number {
  const context = typeof document === "undefined" ? null : document.createElement("canvas").getContext("2d");
  const font = element ? getComputedStyle(element).font : "";
  if (!context || !font) return (text) => text.length * 7;
  context.font = font;
  const cache = new Map<string, number>();
  return (text) => {
    let width = cache.get(text);
    if (width === undefined) {
      width = Math.ceil(context.measureText(text).width);
      cache.set(text, width);
    }
    return width;
  };
}

function anchorOf(element: Element): Anchor {
  const rect = element.getBoundingClientRect();
  return { x: rect.left, y: rect.top, width: rect.width, height: rect.height };
}

export function BookmarksBar(props: BookmarksBarProps) {
  const { snapshot, words, look = "parity", onLayout, onIcons } = props;
  const metrics = metricsFor(look);
  const probe = useRef<HTMLSpanElement>(null);
  const bar = useRef<HTMLDivElement>(null);
  const [rendered, setRendered] = useState(0);
  useLayoutEffect(() => {
    const element = bar.current;
    if (props.width !== undefined || !element) return;
    const read = () => setRendered(element.getBoundingClientRect().width);
    read();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(read);
    observer.observe(element);
    return () => observer.disconnect();
  }, [props.width]);
  const width = props.width ?? rendered;
  const [measured, setMeasured] = useState<((text: string) => number) | null>(null);
  // The bar's font is read once it is on screen; a test passes its own measure.
  useLayoutEffect(() => {
    if (!props.measure) setMeasured(() => canvasMeasure(probe.current));
  }, [props.measure]);
  const measure = props.measure ?? measured ?? ((text: string) => text.length * 7);

  const titles = useMemo(() => snapshot.items.map(displayTitle), [snapshot.items]);
  const otherWidth = snapshot.hasOther ? itemWidth(measure(snapshot.otherTitle), metrics) + metrics.padding : 0;
  const layout = useMemo(
    () =>
      layoutBar(
        titles.map((title) => itemWidth(title ? measure(title) : 0, metrics)),
        width,
        otherWidth,
        metrics,
      ),
    // `measure` changes identity with the font only.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [titles, width, otherWidth, measured, look],
  );
  const visible = snapshot.items.slice(0, layout.visible);

  // Icons are asked for only for the items on screen.
  useEffect(() => {
    if (visible.length > 0) onIcons(visible);
  });

  // The host hears what shows after each change of it (not each render). The profile is part of
  // the report, so a page lent to another profile's bar always reports its new row.
  const reported = useRef("");
  useLayoutEffect(() => {
    // Not measured yet (the first commit): the report waits for the real width.
    if (!snapshot.loaded || !onLayout || width <= 0) return;
    const laidOut: LaidOut = {
      profile: snapshot.profile,
      visible: visible.map((node, index) => ({
        id: node.id,
        title: titles[index] ?? "",
        x: layout.frames[index]?.x ?? 0,
        width: layout.frames[index]?.width ?? 0,
      })),
      overflow: titles.slice(layout.visible),
    };
    const key = JSON.stringify(laidOut);
    if (key === reported.current) return;
    reported.current = key;
    onLayout(laidOut);
  });

  const [drop, setDrop] = useState<number | null>(null);
  const slotAt = (event: DragEvent) => {
    const left = event.currentTarget.getBoundingClientRect().left;
    return insertionIndex(layout.frames, event.clientX - left);
  };
  const onDragOver = (event: DragEvent<HTMLDivElement>) => {
    const types = Array.from(event.dataTransfer.types);
    const own = types.includes(DRAG_TYPE);
    if (!own && !types.includes("text/uri-list")) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = own ? "move" : "copy";
    setDrop(slotAt(event));
  };
  const onDragLeave = (event: DragEvent<HTMLDivElement>) => {
    if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setDrop(null);
  };
  const onDrop = (event: DragEvent<HTMLDivElement>) => {
    event.preventDefault();
    setDrop(null);
    const slot = slotAt(event);
    const data = event.dataTransfer;
    const id = data.getData(DRAG_TYPE);
    if (id) return props.onMove(id, slot);
    const url = droppedURL(data.getData("text/uri-list"), data.getData("text/plain"));
    if (url) props.onDrop(url, droppedTitle(data.getData("text/html"), url), slot);
  };

  const onBarMenu = (event: MouseEvent) => {
    event.preventDefault();
    props.onContextMenu(null, { x: event.clientX, y: event.clientY });
  };

  const empty = snapshot.loaded && snapshot.items.length === 0;
  // The page fills its host (`--bb-height: 100vh`); the gallery draws the native height.
  return (
    <div
      ref={bar}
      className="bb-bar"
      role="toolbar"
      tabIndex={-1}
      aria-label={words.barTitle}
      data-look={look}
      // The title and URL tooltip is taller than the 28 px bar: the system draws it, past the view.
      data-native-title=""
      data-ready={snapshot.loaded ? "" : undefined}
      style={{ height: `var(--bb-height, ${barHeight(metrics)}px)` }}
      onContextMenu={onBarMenu}
      onDragOver={onDragOver}
      onDragLeave={onDragLeave}
      onDrop={onDrop}
    >
      <span ref={probe} className="bb-title bb-probe" aria-hidden="true">
        M
      </span>
      {visible.map((node, index) => (
        <BarItem
          key={node.id}
          node={node}
          title={titles[index] ?? ""}
          frame={layout.frames[index] ?? { x: 0, width: 0 }}
          metrics={metrics}
          icon={snapshot.icons[iconKey(node)]}
          onOpen={props.onOpen}
          onFolder={props.onFolder}
          onContextMenu={props.onContextMenu}
        />
      ))}
      {layout.overflow ? (
        <button
          type="button"
          className="bb-item bb-chevron"
          aria-label={words.more}
          aria-haspopup="menu"
          style={{
            left: layout.chevronX,
            width: metrics.itemHeight,
            height: metrics.itemHeight,
            top: `calc(50% - ${metrics.itemHeight / 2}px)`,
          }}
          onClick={(event) => props.onOverflow(layout.visible, anchorOf(event.currentTarget))}
        >
          <ChevronsGlyph />
        </button>
      ) : null}
      {empty ? (
        <span className="bb-empty" style={{ insetInlineEnd: otherWidth + metrics.inset }}>
          {words.emptyHint}
        </span>
      ) : null}
      {snapshot.hasOther ? (
        <button
          type="button"
          className="bb-item bb-other"
          aria-haspopup="menu"
          style={{
            right: metrics.inset,
            width: otherWidth,
            height: metrics.itemHeight,
            top: `calc(50% - ${metrics.itemHeight / 2}px)`,
          }}
          onClick={(event) => props.onOther(anchorOf(event.currentTarget))}
        >
          <span className="bb-icon" aria-hidden="true">
            <FolderGlyph />
          </span>
          <span className="bb-title">{snapshot.otherTitle}</span>
        </button>
      ) : null}
      {drop !== null ? (
        <span className="bb-drop" style={{ left: indicatorX(layout.frames, drop, metrics) - 1 }} aria-hidden="true" />
      ) : null}
    </div>
  );
}

interface ItemProps {
  node: Bookmark;
  title: string;
  frame: { x: number; width: number };
  metrics: BarMetrics;
  icon?: BarIcon | null;
  onOpen: BookmarksBarProps["onOpen"];
  onFolder: BookmarksBarProps["onFolder"];
  onContextMenu: BookmarksBarProps["onContextMenu"];
}

function BarItem({ node, title, frame, metrics, icon, onOpen, onFolder, onContextMenu }: ItemProps) {
  const folder = node.kind === "folder";
  // A middle press acts once on its release. Older WebKit sends no auxclick, so the release is
  // also heard as pointerup and mouseup; whichever comes first acts and the others find it done.
  const middle = useRef<"pressed" | "done" | null>(null);
  const middleDown = (event: MouseEvent) => {
    if (event.button !== 1) return;
    event.preventDefault();
    if (middle.current !== "pressed") middle.current = "pressed";
  };
  const middleUp = (event: MouseEvent, isAuxClick = false) => {
    if (event.button !== 1) return;
    event.preventDefault();
    if (middle.current === "done") {
      // auxclick is the last event of a press: the next press starts clean.
      if (isAuxClick) middle.current = null;
      return;
    }
    // An auxclick with no press heard (none came to this item) still acts once.
    if (middle.current === null && !isAuxClick) return;
    middle.current = isAuxClick ? null : "done";
    // A middle click acts as a click on a folder (its menu), as the native bar's did.
    if (folder) onFolder(node, anchorOf(event.currentTarget));
    else onOpen(node, disposition(event, true));
  };
  const tip = !folder && node.url ? `${title}\n${node.url}` : title;
  return (
    <button
      type="button"
      className="bb-item"
      draggable
      // tooltip-allow: the native bar's title and URL tooltip, drawn by the system (data-native-title)
      title={tip}
      aria-label={title}
      aria-haspopup={folder ? "menu" : undefined}
      style={{
        left: frame.x,
        width: frame.width,
        height: metrics.itemHeight,
        top: `calc(50% - ${metrics.itemHeight / 2}px)`,
        paddingInline: metrics.padding,
      }}
      onClick={(event) => {
        if (folder) onFolder(node, anchorOf(event.currentTarget));
        else onOpen(node, disposition(event));
      }}
      onPointerDown={middleDown}
      onMouseDown={middleDown}
      onPointerUp={(event) => middleUp(event)}
      onMouseUp={(event) => middleUp(event)}
      onAuxClick={(event) => middleUp(event, true)}
      onPointerLeave={() => {
        // A press that leaves the item is not a click on it.
        if (middle.current === "pressed") middle.current = null;
      }}
      onContextMenu={(event) => {
        event.preventDefault();
        event.stopPropagation();
        onContextMenu(node.id, { x: event.clientX, y: event.clientY });
      }}
      onDragStart={(event) => {
        event.dataTransfer.setData(DRAG_TYPE, node.id);
        if (node.url) {
          event.dataTransfer.setData("text/uri-list", node.url);
          event.dataTransfer.setData("text/plain", node.url);
        }
        event.dataTransfer.effectAllowed = "copyMove";
      }}
    >
      <span className="bb-icon" aria-hidden="true">
        {icon?.mask ? (
          <span className="bb-icon-mask" style={{ maskImage: `url("${icon.src}")` }} />
        ) : icon ? (
          <img src={icon.src} alt="" draggable={false} />
        ) : folder ? (
          <FolderGlyph />
        ) : (
          <GlobeGlyph />
        )}
      </span>
      {title ? <span className="bb-title">{title}</span> : null}
    </button>
  );
}

function ChevronsGlyph() {
  return (
    <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
      <path
        d="M4 4.5L7.5 8 4 11.5M8.5 4.5L12 8l-3.5 3.5"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.3"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
