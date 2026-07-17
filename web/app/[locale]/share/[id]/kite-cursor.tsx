"use client";

import { useId } from "react";
import { participantColor } from "./palette";

const KITE_PATH =
  "M 0.68 1.83 L 3.63 9.78 Q 4.67 12.59 5.3 9.66 L 5.44 9.01 Q 6.08 6.08 9.01 5.44 L 9.66 5.3 Q 12.59 4.67 9.78 3.63 L 1.83 0.68 Q 0 0 0.68 1.83 Z";

export function KiteCursor({
  colorIndex,
  size = 22,
}: {
  colorIndex: number;
  size?: number;
}) {
  const gradientId = useId();
  const { stops } = participantColor(colorIndex);
  return (
    <svg
      width={size}
      height={size}
      viewBox="-1 -1 20.59 20.59"
      aria-hidden="true"
      style={{ display: "block", overflow: "visible" }}
    >
      <defs>
        <linearGradient id={gradientId} x1="0" y1="0" x2="1" y2="1">
          {stops.map((stop, i) => (
            <stop
              key={stop + i}
              offset={stops.length === 1 ? 0 : i / (stops.length - 1)}
              stopColor={stop}
            />
          ))}
        </linearGradient>
      </defs>
      <path
        d={KITE_PATH}
        fill={`url(#${gradientId})`}
        stroke="#ffffff"
        strokeWidth={1.7}
        strokeLinejoin="round"
        style={{ paintOrder: "stroke" }}
      />
    </svg>
  );
}
