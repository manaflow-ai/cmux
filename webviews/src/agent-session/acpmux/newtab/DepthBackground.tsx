// The New Tab page's depth layer (experiment new-tab-depth, depthBackground.experiment.ts): what sits
// behind the page, under its content, for depth. Leo's reference: "bold dark cards, and a live layer
// behind the UI for depth". One absolutely placed layer at --layer-backdrop inside the page's host
// (`.nt-depth-host`, which only exists while an arm other than `off` runs), so the page's own layout
// is the same box as without it: nothing shifts, and the page scrolls over a layer that stays put.
//
// Arms (depth.css draws them):
// - `layers`: the ui/motion DepthLayer in its parallax look: two accent washes at two depths that lean
//   toward the pointer on its events only, and settle within --cmux-motion-large of the last one.
// - `grain`: a still grain and a vignette. Nothing moves.
// - `fields`: three soft accent fields; a hovered or focused chat card shifts them once (a CSS
//   transition on `translate` and `opacity`), then they rest.
// - `backdrop`: an edge scrim over the window's own picture (the page is clear over it when the person
//   set one), and the chat cards turn solid and raised.
//
// Stop conditions: no timer, no frame loop and no infinite animation in any arm. Reduce Motion or
// motion off: the layer is drawn and never moves (DepthLayer reads motionMode(); depth.css stills the
// fields under the same root attributes and media query).
import type { RefObject } from "react";
import { DepthLayer } from "../../../ui/motion/DepthLayer";
import type { NewTabDepthArm } from "./depthBackground.experiment";
import "./depth.css";

export function DepthBackground({ arm, host }: { arm: NewTabDepthArm; host: RefObject<HTMLElement | null> }) {
  if (arm === "off") return null;
  if (arm === "layers") return <DepthLayer look="parallax" surface={host} className="nt-depth" />;
  return (
    <div className="nt-depth" data-depth={arm} aria-hidden="true">
      {arm === "grain" && (
        <>
          <span className="nt-depth-vignette" />
          <span className="nt-depth-grain" />
        </>
      )}
      {arm === "fields" && (
        <>
          <span className="nt-depth-field" data-field="a" />
          <span className="nt-depth-field" data-field="b" />
          <span className="nt-depth-field" data-field="c" />
        </>
      )}
      {arm === "backdrop" && <span className="nt-depth-vignette" />}
    </div>
  );
}
