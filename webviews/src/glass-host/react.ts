// The optional React binding of the glass host (index.ts): React is its only import, as a peer.
import { type RefObject, useEffect, useState } from "react";
import type { GlassHost, GlassLevel, GlassSurfacePhase } from "./index";

/** Puts the element `ref` points at on the app's glass while `open`, following its box. Returns its
 * phase: render nothing different for it; the attached element's `data-glass-host` attribute and
 * `glassHostCss` hide it until drawn and drop its own fill once drawn. */
export function useGlassSurface(
  host: GlassHost | null | undefined,
  ref: RefObject<Element | null>,
  { level = "popover", open = true }: { level?: GlassLevel; open?: boolean } = {},
): GlassSurfacePhase | undefined {
  const [phase, setPhase] = useState<GlassSurfacePhase | undefined>(undefined);
  useEffect(() => {
    const element = ref.current;
    if (!host || !element || !open) return;
    const surface = host.attach(element, { level });
    setPhase(surface.phase);
    let live = true;
    void surface.ready.then(() => {
      if (live) setPhase(surface.phase);
    });
    return () => {
      live = false;
      surface.close();
      setPhase(undefined);
    };
  }, [host, ref, level, open]);
  return phase;
}
