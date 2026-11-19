// How a glass surface asks the glass engine to draw it: `useGlassEngine(ref, look, on)`. While `on`
// (a prototype passes its Experiments switch) and the page can draw (a still of the wallpaper,
// WebGL2, no Reduce Transparency), the engine draws the surface's glass under it and the element
// carries `data-glass-engine`; the surface then drops its own CSS glass (the return value, or the
// attribute in CSS). Off, nothing registers and the surface keeps today's glass.
import { useEffect, useRef, useState, type RefObject } from "react";
import { registerGlassSurface, updateGlassSurface } from "./pageGlass";
import type { GlassLook } from "./optics";

/** Whether the engine draws `ref`'s glass now. */
export function useGlassEngine(
  ref: RefObject<Element | null>,
  look: Partial<GlassLook> | undefined,
  on: boolean,
): boolean {
  const [drawn, setDrawn] = useState(false);
  const lookRef = useRef(look);
  lookRef.current = look;
  useEffect(() => {
    const element = ref.current;
    if (!on || !element) {
      setDrawn(false);
      return;
    }
    const unregister = registerGlassSurface(element, lookRef.current, setDrawn);
    return () => {
      unregister();
      setDrawn(false);
    };
  }, [ref, on]);
  const lookKey = JSON.stringify(look ?? null);
  useEffect(() => {
    const element = ref.current;
    if (on && element) updateGlassSurface(element, lookRef.current);
  }, [ref, on, lookKey]);
  return on && drawn;
}
