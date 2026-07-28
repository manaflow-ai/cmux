"use client";

// Remote cursor layer: the kite cursor (vector path from the computer-use
// overlay, Sources/App/AgentCursorPointerView.swift) recolored per
// participant, plus Figma-style chat bubbles anchored at the cursor.

import type { CSSProperties, ReactNode } from "react";

import { participantColor } from "./share-colors";
import type { RemoteCursor } from "./share-connection";
import type { Participant } from "./share-protocol";
import type { PaneRectRegistry } from "./share-panes";
import { paneKeyOf } from "./share-panes";

/** Sky kite silhouette; tip at the origin pointing up-left, never rotated. */
const KITE_PATH =
  "M0.68 1.83 L3.63 9.78 Q4.67 12.59 5.3 9.66 L5.44 9.01 Q6.08 6.08 9.01 5.44 " +
  "L9.66 5.3 Q12.59 4.67 9.78 3.63 L1.83 0.68 Q0 0 0.68 1.83 Z";

export function KiteCursor({ color, size = 20 }: { color: string; size?: number }): ReactNode {
  return (
    <svg
      width={size}
      height={size}
      viewBox="-1 -1 15 15"
      aria-hidden
      style={{ display: "block" }}
    >
      <path
        d={KITE_PATH}
        fill={color}
        stroke="#ffffff"
        strokeWidth={1.1}
        strokeLinejoin="round"
        paintOrder="stroke"
      />
    </svg>
  );
}

function cursorStyle(
  cursor: RemoteCursor,
  registry: PaneRectRegistry,
  container: HTMLElement,
): CSSProperties | null {
  if (!cursor.pos) return null;
  const paneEl = registry.get(paneKeyOf(cursor.pos.ws, cursor.pos.pane));
  if (!paneEl) return null;
  const paneRect = paneEl.getBoundingClientRect();
  const containerRect = container.getBoundingClientRect();
  return {
    position: "absolute",
    left: paneRect.left - containerRect.left + cursor.pos.x * paneRect.width,
    top: paneRect.top - containerRect.top + cursor.pos.y * paneRect.height,
    pointerEvents: "none",
    zIndex: 40,
    transition: "left 60ms linear, top 60ms linear",
  };
}

export function CursorLayer({
  cursors,
  participants,
  selfUser,
  activeWs,
  registry,
  container,
}: {
  cursors: ReadonlyMap<string, RemoteCursor>;
  participants: Participant[];
  selfUser: string | null;
  activeWs: string | null;
  registry: PaneRectRegistry;
  container: HTMLElement | null;
}): ReactNode {
  if (!container || !activeWs) return null;
  const byUser = new Map(participants.map((p) => [p.user, p]));
  const rendered: ReactNode[] = [];
  for (const cursor of cursors.values()) {
    if (cursor.user === selfUser) continue;
    // Per-workspace scoping: only cursors in the workspace you are viewing.
    if (cursor.pos && cursor.pos.ws !== activeWs) continue;
    const participant = byUser.get(cursor.user);
    if (!participant) continue;
    const style = cursorStyle(cursor, registry, container);
    if (!style) continue;
    const color = participantColor(participant.color);
    rendered.push(
      <div key={cursor.user} style={style}>
        <KiteCursor color={color} />
        <div className="ml-3 flex max-w-64 flex-col items-start gap-1" style={{ marginTop: -2 }}>
          <span
            className="rounded px-1.5 py-0.5 text-[10px] font-medium leading-tight text-white"
            style={{ backgroundColor: color }}
          >
            {participant.email || participant.user}
          </span>
          {cursor.bubble ? (
            <span
              className="rounded-2xl rounded-tl-sm px-2.5 py-1.5 text-xs leading-snug text-white shadow-lg"
              style={{ backgroundColor: color }}
            >
              {cursor.bubble.text}
            </span>
          ) : null}
        </div>
      </div>,
    );
  }
  return <>{rendered}</>;
}
