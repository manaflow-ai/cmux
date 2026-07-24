"use client";

import { useSyncExternalStore } from "react";

const REFRESH_MS = 30_000;

let cachedNow = 0;
const listeners = new Set<() => void>();
let timer: ReturnType<typeof setInterval> | null = null;

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  if (!timer) {
    cachedNow = Date.now();
    timer = setInterval(() => {
      cachedNow = Date.now();
      for (const l of listeners) l();
    }, REFRESH_MS);
  }
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0 && timer) {
      clearInterval(timer);
      timer = null;
    }
  };
}

function getSnapshot(): number {
  if (cachedNow === 0) cachedNow = Date.now();
  return cachedNow;
}

function getServerSnapshot(): number {
  return 0;
}

/** Coarse clock (30s resolution) for relative timestamps. */
export function useNow(): number {
  return useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
}
