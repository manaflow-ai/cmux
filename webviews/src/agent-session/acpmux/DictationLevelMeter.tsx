// The recent input levels as bars, newest on the right.
import React, { useSyncExternalStore } from "react";
import { readLevel, subscribeLevel } from "./dictation";

export function DictationLevelMeter() {
  const samples = useSyncExternalStore(subscribeLevel, readLevel);
  return (
    <span className="acpmux-mic-meter" aria-hidden="true">
      {samples.map((sample, index) => (
        <span key={index} style={{ transform: `scaleY(${Math.max(0.18, Math.min(1, sample * 1.4))})` }} />
      ))}
    </span>
  );
}
