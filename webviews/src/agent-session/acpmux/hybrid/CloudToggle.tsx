// The cloud button (RFD 0075, Leo 2026-11-23: "a toggleable cloud button, maybe a rainbow cloud
// symbol..... that is dull when not toggled on, and when you toggle it on it becomes a rainbow or
// some hilariously satisfying toggle-on"). One per chat. Off, the chat is Auto: it runs on this Mac
// and pauses when the Mac goes away. On, it is high priority: it holds one of the plan's slots and
// keeps running in Cloud. The turn-on plays once, on the person's own click, never when a chat
// that is already on is drawn; reduced motion shows the lit cloud at once.
import { useId, useState } from "react";
import { useT } from "../i18n";
import { Tooltip } from "../../../ui/Tooltip";
import { cx } from "../../../ui/cx";
import type { HybridLook, HybridView } from "./hybridModel";
import "./cloudToggle.css";

/// `chip`: the cloud and "Keep Running" (the strip above the composer, Session Info).
/// `icon`: the cloud alone (the quiet row under the composer).
export type CloudToggleForm = "chip" | "icon";

const CLOUD = "M4.6 12.5h7a2.6 2.6 0 0 0 .4-5.17A3.6 3.6 0 0 0 5.1 6.2 3.15 3.15 0 0 0 4.6 12.5Z";

export function CloudToggle({
  view,
  look = "rainbow",
  form = "chip",
  className,
  onChange,
}: {
  view: HybridView;
  look?: HybridLook;
  form?: CloudToggleForm;
  className?: string;
  /// The person's click: true asks for a slot, false gives it back.
  onChange(on: boolean): void;
}) {
  const t = useT();
  const paint = useId();
  // Only a click arms the turn-on; it disarms when the animation ends.
  const [fresh, setFresh] = useState(false);
  const on = view.lit || view.waiting === true;
  const slots = t("hybrid.slots", { used: view.used, total: view.total });
  const detail = view.waiting
    ? `${t("hybrid.waiting")} ${slots}`
    : `${t(view.lit ? "hybrid.keepRunning.help" : "hybrid.auto.help")} ${slots}`;
  return (
    <Tooltip label={t("hybrid.keepRunning")} detail={detail} side="top">
      <button
        type="button"
        role="switch"
        aria-checked={on}
        aria-label={t("hybrid.keepRunning")}
        className={cx("acpmux-hybrid-toggle", className)}
        data-testid="hybrid-cloud-toggle"
        data-look={look}
        data-form={form}
        data-lit={view.lit ? "" : undefined}
        data-waiting={view.waiting ? "" : undefined}
        data-fresh={fresh ? "" : undefined}
        onClick={() => {
          setFresh(!on);
          onChange(!on);
        }}
        onAnimationEnd={(event) => {
          if (event.animationName.startsWith("acpmux-hybrid-settle")) setFresh(false);
        }}
      >
        <span className="acpmux-hybrid-glyph" aria-hidden="true">
          <svg className="acpmux-hybrid-arc" viewBox="0 0 32 20" fill="none" focusable="false">
            <path className="acpmux-hybrid-arc__band" data-band="1" d="M3 19a13 13 0 0 1 26 0" />
            <path className="acpmux-hybrid-arc__band" data-band="2" d="M6 19a10 10 0 0 1 20 0" />
            <path className="acpmux-hybrid-arc__band" data-band="3" d="M9 19a7 7 0 0 1 14 0" />
          </svg>
          <svg className="acpmux-hybrid-cloud" width={16} height={16} viewBox="0 0 16 16" focusable="false">
            <defs>
              <linearGradient id={paint} x1="2" y1="12" x2="14" y2="4" gradientUnits="userSpaceOnUse">
                <stop offset="0" className="acpmux-hybrid-stop" data-stop="1" />
                <stop offset="0.25" className="acpmux-hybrid-stop" data-stop="2" />
                <stop offset="0.5" className="acpmux-hybrid-stop" data-stop="3" />
                <stop offset="0.75" className="acpmux-hybrid-stop" data-stop="4" />
                <stop offset="1" className="acpmux-hybrid-stop" data-stop="5" />
              </linearGradient>
            </defs>
            <path
              className="acpmux-hybrid-cloud__shape"
              d={CLOUD}
              style={{ "--acpmux-hybrid-paint": `url(#${CSS.escape(paint)})` } as React.CSSProperties}
            />
          </svg>
        </span>
        {form === "chip" && <span className="acpmux-hybrid-label">{t("hybrid.keepRunning")}</span>}
      </button>
    </Tooltip>
  );
}
