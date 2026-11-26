import { useEffect, useMemo, useRef, useState } from "react";
import type { RenderGraphicImage } from "cmux/raw";
import {
  renderGraphicImageKey,
  type DecodedRenderGraphicImage,
} from "../lib/renderGraphics";
import type { RenderGraphicsDecodeScheduler } from "../lib/renderGraphicsDecodeScheduler";

interface DecodedPixels {
  pixels: Uint8ClampedArray<ArrayBuffer>;
}

export function sameImageGenerations(
  left: readonly RenderGraphicImage[],
  right: readonly RenderGraphicImage[],
): boolean {
  if (left === right) return true;
  if (left.length !== right.length) return false;
  const leftKeys = new Set(left.map(renderGraphicImageKey));
  return right.every((image) => leftKeys.has(renderGraphicImageKey(image)));
}

/** Decode large graphics outside render and cancel work for superseded generations. */
export function useDecodedRenderGraphicImages(
  scheduler: RenderGraphicsDecodeScheduler,
  owner: symbol,
  images: readonly RenderGraphicImage[],
): ReadonlyMap<number, DecodedRenderGraphicImage> {
  const cacheRef = useRef(new Map<string, DecodedPixels | null>());
  const stableImagesRef = useRef(images);
  if (!sameImageGenerations(stableImagesRef.current, images)) {
    stableImagesRef.current = images;
  }
  const stableImages = stableImagesRef.current;
  const [revision, setRevision] = useState(0);
  const decoded = useMemo(() => {
    const current = new Map<number, DecodedRenderGraphicImage>();
    for (const image of stableImages) {
      const cached = cacheRef.current.get(renderGraphicImageKey(image));
      if (cached != null) current.set(image.id, { image, pixels: cached.pixels });
    }
    return current;
  }, [stableImages, revision]);

  useEffect(() => {
    const activeKeys = new Set(stableImages.map(renderGraphicImageKey));
    const pending = stableImages.filter(
      (image) => !cacheRef.current.has(renderGraphicImageKey(image)),
    );
    for (const key of cacheRef.current.keys()) {
      if (!activeKeys.has(key)) cacheRef.current.delete(key);
    }
    if (pending.length === 0) return;

    return scheduler.schedule(owner, pending, (results) => {
      for (const result of results) {
        const key = `${result.id}:${result.generation}`;
        if (activeKeys.has(key)) {
          cacheRef.current.set(
            key,
            result.pixels === null
              ? null
              : { pixels: new Uint8ClampedArray(result.pixels) },
          );
        }
      }
      setRevision((value) => value + 1);
    });
  }, [owner, scheduler, stableImages]);

  return decoded;
}
