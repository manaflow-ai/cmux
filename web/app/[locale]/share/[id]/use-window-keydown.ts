"use client";

import { useEffect, useRef } from "react";

/**
 * Narrow-contract hook: subscribes to window keydown for the component's
 * lifetime and forwards events to the latest handler. This is the one
 * place a raw effect is unavoidable (global listener with cleanup).
 */
export function useWindowKeydown(handler: (event: KeyboardEvent) => void) {
  const handlerRef = useRef(handler);

  useEffect(() => {
    handlerRef.current = handler;
  });

  useEffect(() => {
    const listener = (event: KeyboardEvent) => handlerRef.current(event);
    window.addEventListener("keydown", listener);
    return () => window.removeEventListener("keydown", listener);
  }, []);
}
