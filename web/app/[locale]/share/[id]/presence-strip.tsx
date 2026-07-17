"use client";

import type { Participant } from "./protocol";
import { displayName, participantColor } from "./palette";

export function PresenceStrip({
  participants,
}: {
  participants: Participant[];
}) {
  return (
    <div className="pointer-events-auto fixed right-4 top-4 z-30 flex -space-x-1.5">
      {participants.map((participant) => {
        const color = participantColor(participant.color);
        const name = displayName(participant);
        return (
          <div
            key={participant.id}
            title={name}
            className="flex h-7 w-7 items-center justify-center rounded-full border-2 border-neutral-950 text-[12px] font-semibold text-white"
            style={{ background: color.base }}
          >
            {name.charAt(0).toUpperCase() || "?"}
          </div>
        );
      })}
    </div>
  );
}
