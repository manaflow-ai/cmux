import { useEffect } from "react";
import { debounce } from "../lib/debounce";

export function useVisualViewport() {
  useEffect(() => {
    const root = document.documentElement;
    const viewport = window.visualViewport;
    const update = () => {
      const height = viewport?.height ?? window.innerHeight;
      const offsetTop = viewport?.offsetTop ?? 0;
      root.style.setProperty("--visual-viewport-height", `${height}px`);
      root.style.setProperty("--visual-viewport-offset", `${offsetTop}px`);
    };
    const debouncedUpdate = debounce(update, 50);
    update();
    viewport?.addEventListener("resize", debouncedUpdate);
    viewport?.addEventListener("scroll", debouncedUpdate);
    window.addEventListener("resize", debouncedUpdate);
    return () => {
      viewport?.removeEventListener("resize", debouncedUpdate);
      viewport?.removeEventListener("scroll", debouncedUpdate);
      window.removeEventListener("resize", debouncedUpdate);
      debouncedUpdate.cancel();
    };
  }, []);
}
