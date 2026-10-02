// A ⌘-letter command for the page (⌘K opens search). One document listener while mounted.
import { useEffect, useRef } from "react";

export function useKeyCommand(key: string, run: () => void): void {
  const latest = useRef(run);
  latest.current = run;
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (!event.metaKey || event.ctrlKey || event.altKey || event.shiftKey || event.key.toLowerCase() !== key) return;
      event.preventDefault();
      latest.current();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [key]);
}
