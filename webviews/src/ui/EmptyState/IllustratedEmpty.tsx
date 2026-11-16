// An empty state with a little life in it (Leo, 2026-10-26, on coding GUIs: "they're just gray and
// very sad... it's not cute. It's not happy."): one small static illustration, one plain line and
// one useful button. The art is decorative (alt="", the line says it all) and has a fixed box from
// its width and height attributes, so the line and the button never move when the image loads.
// Without `art` (the pet turned off, or a surface that already draws the mascot beside it) it is
// the line and the button alone, in the same place. It opens in one frame: no fade, no loop.
import { Button } from "../Button";
import { cx } from "../cx";
import "../controls.css";
import "./illustratedEmpty.css";

/** `above`: the art centered over the line and the button. `beside`: one compact row, for a narrow
 * or short slot. */
export type IllustratedEmptyLayout = "above" | "beside";

/** The art's square box, on the layout gaps (design/grid.md). */
export type IllustratedEmptyArtSize = 48 | 56;

export interface IllustratedEmptyProps {
  /** The image's URL (a data URL on a strict-CSP page). Left out: the line and the button only. */
  art?: string;
  line: string;
  action?: { label: string; onClick(): void };
  layout?: IllustratedEmptyLayout;
  artSize?: IllustratedEmptyArtSize;
  className?: string;
}

export function IllustratedEmpty({
  art,
  line,
  action,
  layout = "above",
  artSize = 56,
  className,
}: IllustratedEmptyProps) {
  return (
    <div className={cx("ui-illustrated-empty", className)} data-layout={layout} data-art={art ? artSize : undefined}>
      {art && <img className="ui-illustrated-empty-art" src={art} alt="" width={artSize} height={artSize} />}
      <div className="ui-illustrated-empty-copy">
        <p className="ui-illustrated-empty-line">{line}</p>
        {action && (
          <Button variant="subtle" size="sm" className="ui-illustrated-empty-action" onClick={action.onClick}>
            {action.label}
          </Button>
        )}
      </div>
    </div>
  );
}
