import { useEffect, useMemo, useRef, useState } from "react";
import type { RenderGraphicImage } from "cmux/browser";
import {
  decodeRenderGraphicImage,
  type DecodedRenderGraphicImage,
} from "../lib/renderGraphics";
import type {
  RenderGraphicsDecodeRequest,
  RenderGraphicsDecodeResponse,
} from "../workers/renderGraphicsDecoder";

interface DecodedPixels {
  pixels: Uint8ClampedArray<ArrayBuffer>;
}

function imageKey(image: RenderGraphicImage): string {
  return `${image.id}:${image.generation}`;
}

function decodeWithoutWorker(
  images: readonly RenderGraphicImage[],
): RenderGraphicsDecodeResponse["results"] {
  return images.map((image) => {
    const decoded = decodeRenderGraphicImage(image);
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
  const [revision, setRevision] = useState(0);
  const decoded = useMemo(() => {
    const current = new Map<number, DecodedRenderGraphicImage>();
    for (const image of images) {
      const cached = cacheRef.current.get(imageKey(image));
      if (cached != null) current.set(image.id, { image, pixels: cached.pixels });
    }
    return current;
  }, [images, revision]);

  useEffect(() => {
    const activeKeys = new Set(images.map(imageKey));
    const pending = images.filter((image) => !cacheRef.current.has(imageKey(image)));
    for (const key of cacheRef.current.keys()) {
      if (!activeKeys.has(key)) cacheRef.current.delete(key);
    }
    if (pending.length === 0) return;

    const requestId = ++requestRef.current;
    let canceled = false;
    let worker: Worker | null = null;
    let fallbackTimer: ReturnType<typeof setTimeout> | null = null;
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

    if (typeof Worker === "undefined") {
      fallbackTimer = setTimeout(() => {
        complete({ requestId, results: decodeWithoutWorker(pending) });
      }, 0);
    } else {
      try {
        worker = new Worker(
          new URL("../workers/renderGraphicsDecoder.ts", import.meta.url),
          { type: "module" },
        );
        worker.onmessage = (event: MessageEvent<RenderGraphicsDecodeResponse>) => {
          complete(event.data);
          worker?.terminate();
          worker = null;
        };
        worker.onerror = () => {
          worker?.terminate();
          worker = null;
        };
        const request: RenderGraphicsDecodeRequest = {
          requestId,
          images: [...pending],
        };
        worker.postMessage(request);
      } catch {
        fallbackTimer = setTimeout(() => {
          complete({ requestId, results: decodeWithoutWorker(pending) });
        }, 0);
      }
    }

    return () => {
      canceled = true;
      worker?.terminate();
      if (fallbackTimer !== null) clearTimeout(fallbackTimer);
    };
  }, [images]);

  return decoded;
}
