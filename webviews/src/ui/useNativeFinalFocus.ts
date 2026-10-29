import { useEffect, useRef, type RefObject } from "react";

/** Resolve an explicit page destination after the native popup's closing commit. The close may
 * mount that destination, and React restores the old selection before passive cleanup. */
export function useNativeFinalFocus(open: boolean, finalFocus: RefObject<HTMLElement | null> | boolean | undefined) {
  const latest = useRef(finalFocus);
  latest.current = finalFocus;
  useEffect(() => {
    if (!open) return;
    return () => {
      const target = latest.current;
      if (target && typeof target !== "boolean") target.current?.focus({ preventScroll: true });
    };
  }, [open]);
}
