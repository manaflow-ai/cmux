import { useEffect, useMemo, useRef, useState } from "react";
import type { RenderGraphicImage } from "cmux/browser";
import {
  decodeRenderGraphicImage,
  renderGraphicDecodedByteLength,
  renderGraphicImageKey,
  type DecodedRenderGraphicImage,
} from "../lib/renderGraphics";
import type {
  RenderGraphicsDecodeRequest,
  RenderGraphicsDecodeResponse,
} from "../workers/renderGraphicsDecoder";

interface DecodedPixels {
  pixels: Uint8ClampedArray<ArrayBuffer>;
}

const RENDER_GRAPHIC_MAIN_THREAD_FALLBACK_MAX_DECODED_BYTES = 256 * 1024;

function sameImageGenerations(
  left: readonly RenderGraphicImage[],
  right: readonly RenderGraphicImage[],
): boolean {
  if (left.length !== right.length) return false;
  const leftKeys = new Set(left.map(renderGraphicImageKey));
  return right.every((image) => leftKeys.has(renderGraphicImageKey(image)));
}

function decodeWithoutWorker(
  images: readonly RenderGraphicImage[],
): RenderGraphicsDecodeResponse["results"] {
  return images.map((image) => {
    // A failed or unavailable worker must not turn a multi-megabyte validation
    // scan and decode into one long task on the browser thread.
    const byteLength = renderGraphicDecodedByteLength(image);
    const decoded = byteLength !== null
      && byteLength <= RENDER_GRAPHIC_MAIN_THREAD_FALLBACK_MAX_DECODED_BYTES
      ? decodeRenderGraphicImage(image)
      : null;
    return {
      id: image.id,
      generation: image.generation,
      pixels: decoded?.pixels.buffer ?? null,
    };
  });
}

/** Decode large graphics outside render and cancel work for superseded generations. */
export function useDecodedRenderGraphicImages(
  images: readonly RenderGraphicImage[],
): ReadonlyMap<number, DecodedRenderGraphicImage> {
  const cacheRef = useRef(new Map<string, DecodedPixels | null>());
  const requestRef = useRef(0);
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

    const requestId = ++requestRef.current;
    let canceled = false;
    let worker: Worker | null = null;
    let settled = false;
    const complete = (response: RenderGraphicsDecodeResponse) => {
      if (canceled || response.requestId !== requestId) return;
      for (const result of response.results) {
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
    };
    const runFallback = () => {
      if (canceled || settled) return;
      settled = true;
      worker?.terminate();
      worker = null;
      queueMicrotask(() => {
        complete({ requestId, results: decodeWithoutWorker(pending) });
      });
    };

    if (typeof Worker === "undefined") {
      runFallback();
    } else {
      try {
        worker = new Worker(
          new URL("../workers/renderGraphicsDecoder.ts", import.meta.url),
          { type: "module" },
        );
        worker.onmessage = (event: MessageEvent<RenderGraphicsDecodeResponse>) => {
          if (event.data.requestId !== requestId) {
            runFallback();
            return;
          }
          settled = true;
          complete(event.data);
          worker?.terminate();
          worker = null;
        };
        worker.onerror = runFallback;
        worker.onmessageerror = runFallback;
        const request: RenderGraphicsDecodeRequest = {
          requestId,
          images: [...pending],
        };
        worker.postMessage(request);
      } catch {
        runFallback();
      }
    }

    return () => {
      canceled = true;
      worker?.terminate();
    };
  }, [stableImages]);

  return decoded;
}
