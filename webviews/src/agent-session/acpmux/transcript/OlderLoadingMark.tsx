// The older history's loading mark (cmux#48605), drawn only while it is in view. It sits just above the
// first loaded row, in the room held for older history, which is above the view for as long as a reader
// stays near the latest turns. A `cmux-spin` loop there kept running unseen, so a chat left alone woke
// every frame (goal idle-wakeups: NOW `idle_chat_rest_wakeups_per_s`, 0 on 2026-11-21, 1 per 10 s after
// #48720). The box stays, with its label, so the status is announced all along; only the spinner waits
// for the reader. The shared spinner clock (ui/spinnerClock.ts) pins the phase, so it never jumps in.
import { useEffect, useRef, useState, type CSSProperties } from "react";
import { Spinner } from "../conversation/icons";

export function OlderLoadingMark({ label, style }: { label: string; style: CSSProperties }) {
  const box = useRef<HTMLOutputElement>(null);
  // Where there is no IntersectionObserver the mark draws, as before.
  const [seen, setSeen] = useState(() => typeof IntersectionObserver === "undefined");
  useEffect(() => {
    const element = box.current;
    if (!element || typeof IntersectionObserver === "undefined") return;
    // observer: one per mark (at most one per transcript); disconnected when the mark leaves.
    const observer = new IntersectionObserver((entries) => {
      const entry = entries.at(-1);
      if (entry) setSeen(entry.isIntersecting);
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  return (
    <output ref={box} className="acpmux-older-loading" aria-label={label} style={style}>
      {seen && <Spinner size={16} loading />}
    </output>
  );
}
