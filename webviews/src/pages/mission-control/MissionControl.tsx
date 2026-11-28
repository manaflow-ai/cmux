// Mission control's grid (model.ts): a scroller of session tiles that mounts only the rows near the
// viewport, between a sized stage that keeps the scroll bar true. Each tile reads its own entry, never
// the list, so a change to one session re-renders one tile.
import { memo, useLayoutEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { Button } from "../../ui/Button";
import { Spinner } from "../../agent-session/acpmux/conversation/icons";
import { StatusGlyph } from "../../ui/StatusGlyph";
import {
  DEFAULT_METRICS,
  countByState,
  gridLayout,
  visibleRange,
  type MissionGridMetrics,
  type MissionTile,
  type MissionTileState,
} from "./model";

export interface MissionControlStrings {
  title: string;
  working: string;
  waiting: string;
  done: string;
  noPicture: string;
  empty: string;
}

/** Where a tile's badge sits: over the picture's corner, or in the caption before the title. */
export type MissionBadgePlace = "corner" | "caption";

export interface MissionControlProps {
  tiles: readonly MissionTile[];
  strings: MissionControlStrings;
  metrics?: MissionGridMetrics;
  badge?: MissionBadgePlace;
  /** The viewport before the scroller is measured (tests, the first frame): width and height in CSS px. */
  initialViewport?: { width: number; height: number; top?: number };
  onOpen?(id: string): void;
}

function badgeLabel(state: MissionTileState, strings: MissionControlStrings): string {
  return state === "working" ? strings.working : state === "waiting" ? strings.waiting : strings.done;
}

function Badge({ state, label }: { state: MissionTileState; label: string }) {
  return (
    <span className={`mc-badge mc-badge-${state}`} aria-label={label} role="img">
      {state === "working" ? <Spinner size={12} /> : <StatusGlyph name={state} size={12} />}
      <span className="mc-badge-text">{label}</span>
    </span>
  );
}

const MissionTileCard = memo(function MissionTileCard({
  tile,
  style,
  badge,
  strings,
  onOpen,
}: {
  tile: MissionTile;
  style: CSSProperties;
  badge: MissionBadgePlace;
  strings: MissionControlStrings;
  onOpen?(id: string): void;
}) {
  const label = badgeLabel(tile.state, strings);
  return (
    <Button
      bare
      className={`mc-tile mc-tile-${tile.state}`}
      style={style}
      data-tile={tile.id}
      data-kind={tile.kind}
      aria-label={`${tile.title}, ${tile.machineName}, ${label}`}
      onClick={() => onOpen?.(tile.id)}
    >
      <span className="mc-thumb">
        {tile.thumb ? (
          <img src={tile.thumb.src} alt="" draggable={false} decoding="async" loading="lazy" />
        ) : (
          <span className="mc-thumb-empty">{strings.noPicture}</span>
        )}
        {badge === "corner" ? <Badge state={tile.state} label={label} /> : null}
      </span>
      <span className="mc-caption">
        {badge === "caption" ? <Badge state={tile.state} label={label} /> : null}
        <span className="mc-title">{tile.title}</span>
        <span className="mc-meta">
          {tile.machineName}
          {tile.age ? ` · ${tile.age}` : ""}
        </span>
      </span>
    </Button>
  );
});

export function MissionControl({
  tiles,
  strings,
  metrics = DEFAULT_METRICS,
  badge = "corner",
  initialViewport,
  onOpen,
}: MissionControlProps) {
  const scroller = useRef<HTMLDivElement>(null);
  const [viewport, setViewport] = useState(() => ({
    width: initialViewport?.width ?? 0,
    height: initialViewport?.height ?? 0,
    top: initialViewport?.top ?? 0,
  }));

  useLayoutEffect(() => {
    const node = scroller.current;
    if (!node) return;
    let frame = 0;
    const measure = () => {
      frame = 0;
      setViewport((last) => {
        const next = { width: node.clientWidth, height: node.clientHeight, top: node.scrollTop };
        return next.width === last.width && next.height === last.height && next.top === last.top ? last : next;
      });
    };
    const schedule = () => {
      if (!frame) frame = requestAnimationFrame(measure);
    };
    measure();
    node.addEventListener("scroll", schedule, { passive: true });
    const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(schedule);
    observer?.observe(node);
    return () => {
      node.removeEventListener("scroll", schedule);
      observer?.disconnect();
      if (frame) cancelAnimationFrame(frame);
    };
  }, []);

  const count = tiles.length;
  const layout = useMemo(() => gridLayout(count, viewport.width, metrics), [count, viewport.width, metrics]);
  const { start, end } = visibleRange(count, layout, viewport);
  const counts = useMemo(() => countByState(tiles), [tiles]);

  const mounted: ReactNode[] = [];
  for (let index = start; index < end; index += 1) {
    const tile = tiles[index]!;
    const row = Math.floor(index / layout.columns);
    const column = index % layout.columns;
    const style: CSSProperties = {
      width: layout.tileWidth,
      height: layout.tileHeight,
      transform: `translate(${column * (layout.tileWidth + metrics.gap)}px, ${row * layout.stride}px)`,
    };
    mounted.push(
      <MissionTileCard key={tile.id} tile={tile} style={style} badge={badge} strings={strings} onOpen={onOpen} />,
    );
  }

  return (
    <div className="mc-page" data-tiles={count} data-mounted={end - start}>
      <header className="mc-header">
        <h1 className="mc-heading">{strings.title}</h1>
        <span className="mc-counts">
          {counts.waiting > 0 ? <Badge state="waiting" label={`${counts.waiting} ${strings.waiting}`} /> : null}
          {counts.working > 0 ? <Badge state="working" label={`${counts.working} ${strings.working}`} /> : null}
          {counts.done > 0 ? <Badge state="done" label={`${counts.done} ${strings.done}`} /> : null}
        </span>
      </header>
      <div className="mc-scroller" ref={scroller}>
        {count === 0 ? (
          <p className="mc-empty">{strings.empty}</p>
        ) : (
          <div className="mc-stage" style={{ height: layout.height }}>
            {mounted}
          </div>
        )}
      </div>
    </div>
  );
}
