"use client";

import type { Participant } from "./protocol";
import { displayName, participantColor } from "./palette";
import { KiteCursor } from "./kite-cursor";

export interface RemoteCursor {
  participantId: string;
  x: number;
  y: number;
}

export interface CursorBubble {
  id: number;
  participantId: string;
  text: string;
}

/**
 * Renders remote participant cursors + their transient chat bubbles in
 * workspace coordinates. Positions are normalized [0,1] and mapped to the
 * unscaled workspace size; the parent applies the fit-to-viewport scale.
 */
export function CursorLayer({
  cursors,
  bubbles,
  participants,
  workspaceWidth,
  workspaceHeight,
  selfParticipantId,
}: {
  cursors: RemoteCursor[];
  bubbles: CursorBubble[];
  participants: Map<string, Participant>;
  workspaceWidth: number;
  workspaceHeight: number;
  selfParticipantId: string | null;
}) {
  return (
    <div className="pointer-events-none absolute inset-0 overflow-visible">
      {cursors.map((cursor) => {
        if (cursor.participantId === selfParticipantId) return null;
        const participant = participants.get(cursor.participantId);
        const colorIndex = participant?.color ?? 0;
        const color = participantColor(colorIndex);
        const bubble = bubbles.findLast(
          (b) => b.participantId === cursor.participantId,
        );
        return (
          <div
            key={cursor.participantId}
            className="absolute left-0 top-0"
            style={{
              transform: `translate(${cursor.x * workspaceWidth}px, ${cursor.y * workspaceHeight}px)`,
              transition: "transform 80ms linear",
            }}
          >
            <KiteCursor colorIndex={colorIndex} />
            <div
              className="absolute left-[18px] top-[18px] max-w-[220px] whitespace-nowrap rounded-full px-2 py-0.5 text-[11px] font-medium text-white"
              style={{ background: color.base }}
            >
              {participant ? displayName(participant) : "…"}
            </div>
            {bubble ? (
              <div
                className="absolute left-[18px] top-[42px] max-w-[280px] rounded-2xl rounded-tl-sm px-3 py-1.5 text-[12px] leading-4 text-white shadow-lg"
                style={{ background: color.base }}
              >
                {bubble.text}
              </div>
            ) : null}
          </div>
        );
      })}
    </div>
  );
}
