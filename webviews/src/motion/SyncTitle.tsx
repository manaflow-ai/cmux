// A synced title that changes in place (sync motion model, plans/cmux-next/sync-ux/DESIGN.md 1.4).
// A rename keeps the row's key, so this component sees the old and the new text: it draws the old
// text over the new one and crossfades them (old out on `fadeOut`, new in on `fadeIn`). When the
// title box sizes to its text (a tab title, `fit`), its width springs from the old text's width to
// the new on `move`, so the neighbours slide instead of popping; a title that fills its row (a
// sidebar row, which truncates) keeps its width and only crossfades. Reduce Motion keeps the
// crossfade at `crossfade` at most (motion.md rule 7) and drops the width spring. `animate` false
// (the first draw, a snapshot, an off-screen row, a burst, the local user's own optimistic rename)
// swaps the text in one frame.
import { type CSSProperties, useLayoutEffect, useRef, useState } from "react";
import { springSamples, SYNC_FADES, SYNC_SPRINGS } from "./syncMotion";

export type SyncTitleProps = {
  text: string;
  /** Crossfade this change (from SyncListMotion.renames). */
  animate: boolean;
  /** The box sizes to the text (tabs): its width springs to the new text. */
  fit?: boolean;
  className?: string;
  style?: CSSProperties;
};

export function SyncTitle({ text, animate, fit = false, className, style }: SyncTitleProps) {
  const [leaving, setLeaving] = useState<{ text: string; key: number } | null>(null);
  const shown = useRef(text);
  const box = useRef<HTMLSpanElement>(null);
  const width = useRef<number | null>(null);
  const counter = useRef(0);
  useLayoutEffect(() => {
    const element = box.current;
    const previous = shown.current;
    shown.current = text;
    const before = width.current;
    const after = element?.getBoundingClientRect().width ?? null;
    width.current = after;
    if (previous === text || !animate || !element) {
      if (previous !== text) setLeaving(null);
      return;
    }
    const reduced = globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
    counter.current += 1;
    setLeaving({ text: previous, key: counter.current });
    const fresh = element.querySelector<HTMLElement>("[data-sync-title=current]");
    fresh?.animate([{ opacity: 0 }, { opacity: 1 }], {
      duration: reduced ? SYNC_FADES.crossfade : SYNC_FADES.fadeIn,
      easing: "ease-out",
    });
    if (fit && !reduced && before !== null && after !== null && Math.abs(before - after) > 0.5) {
      const move = springSamples(SYNC_SPRINGS.move);
      element.animate(
        move.progress.map((value, index) => ({
          offset: index / (move.progress.length - 1),
          width: `${(before + (after - before) * value).toFixed(2)}px`,
        })),
        { duration: move.durationMs },
      );
    }
  }, [text, animate, fit]);
  return (
    <span
      ref={box}
      className={className}
      data-sync-title-box=""
      style={{ position: "relative", display: fit ? "inline-block" : "block", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", ...style }}
    >
      <span data-sync-title="current">{text}</span>
      {leaving && (
        <LeavingTitle
          key={leaving.key}
          text={leaving.text}
          onDone={() => setLeaving((current) => (current?.key === leaving.key ? null : current))}
        />
      )}
    </span>
  );
}

function LeavingTitle({ text, onDone }: { text: string; onDone(): void }) {
  const element = useRef<HTMLSpanElement>(null);
  useLayoutEffect(() => {
    const reduced = globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
    const fade = element.current?.animate([{ opacity: 1 }, { opacity: 0 }], {
      duration: reduced ? SYNC_FADES.crossfade : SYNC_FADES.fadeOut,
      easing: "ease-out",
      fill: "forwards",
    });
    if (!fade) return onDone();
    fade.onfinish = onDone;
    return () => fade.cancel();
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- one fade per mount.
  }, []);
  return (
    <span
      ref={element}
      aria-hidden="true"
      data-sync-title="leaving"
      style={{ position: "absolute", inset: 0, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", pointerEvents: "none" }}
    >
      {text}
    </span>
  );
}
