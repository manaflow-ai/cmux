// The frames of a turn as a filmstrip under its edited-files card, next to the before and after
// pair (turnChanges/TurnShotsPair.tsx): thumbnails in one horizontal row, a click opens that frame
// in the chat's image viewer. Draws nothing without a reader (no `turn-frames-v1`) or without
// frames.
import { useContext, useEffect, useState } from "react";
import { ImageViewerContext } from "../conversation/imageViewerContext";
import { useT } from "../i18n";
import { TurnFramesContext } from "./framesCache";
import type { TurnFrame } from "./turnFrames";
import "./liveFrames.css";

export function TurnFramesStrip({ rowId }: { rowId: string }) {
  const reader = useContext(TurnFramesContext);
  const openImage = useContext(ImageViewerContext);
  const t = useT();
  const [arrived, setArrived] = useState<{ rowId: string; frames: TurnFrame[] }>();
  useEffect(() => {
    if (!reader || reader.peek(rowId)) return;
    let live = true;
    void reader.read(rowId).then((frames) => {
      if (live) setArrived({ rowId, frames });
    });
    return () => {
      live = false;
    };
  }, [reader, rowId]);
  const fresh = arrived?.rowId === rowId ? arrived : undefined;
  const frames = fresh ? fresh.frames : (reader?.peek(rowId)?.frames ?? []);
  if (!reader || frames.length === 0) return null;
  // The list carries 320 px thumbs; the viewer asks for the whole picture and keeps the thumb when
  // the daemon has none (or is an older one).
  const open = async (frame: TurnFrame, alt: string) => {
    const full = (await reader.full?.(rowId, frame.index)) ?? frame.full;
    openImage?.(full, alt);
  };
  return (
    <section className="acpmux-frames-strip" aria-label={t("turnFrames.title")}>
      <ul className="acpmux-frames-strip__row">
        {frames.map((frame) => {
          const alt = t("turnFrames.alt", { n: frame.index + 1 });
          return (
            <li key={frame.index} className="acpmux-frames-strip__item">
              <button
                type="button"
                className="acpmux-frames-strip__frame"
                title={frame.trigger ? `${alt}: ${frame.trigger}` : alt}
                onClick={() => void open(frame, alt)}
                disabled={!openImage}
              >
                <img src={frame.thumb} alt={alt} loading="lazy" draggable={false} />
              </button>
            </li>
          );
        })}
      </ul>
    </section>
  );
}
