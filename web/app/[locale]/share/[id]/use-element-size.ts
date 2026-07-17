"use client";

import { useCallback, useRef, useState } from "react";

export interface ElementSize {
  width: number;
  height: number;
}

/**
 * Observes an element's content box via ResizeObserver behind a callback
 * ref (no useEffect). Returns [ref, size].
 */
export function useElementSize(): [
  (node: HTMLElement | null) => void,
  ElementSize,
] {
  const [size, setSize] = useState<ElementSize>({ width: 0, height: 0 });
  const observerRef = useRef<ResizeObserver | null>(null);

  const ref = useCallback((node: HTMLElement | null) => {
    observerRef.current?.disconnect();
    observerRef.current = null;
    if (!node) return;
    const observer = new ResizeObserver((entries) => {
      const entry = entries[entries.length - 1];
      if (!entry) return;
      const box = entry.contentRect;
      setSize((prev) =>
        prev.width === box.width && prev.height === box.height
          ? prev
          : { width: box.width, height: box.height },
      );
    });
    observer.observe(node);
    observerRef.current = observer;
    const rect = node.getBoundingClientRect();
    setSize({ width: rect.width, height: rect.height });
  }, []);

  return [ref, size];
}
