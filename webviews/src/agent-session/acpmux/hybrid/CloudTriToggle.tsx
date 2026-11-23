// The three-state cloud control (Leo, 2026-11-23 11:08Z: "we can potentially have a split cloud /
// computer looking button, then full cloud, then only computer"). Hybrid is the default: the chat
// runs on this Mac and continues in Cloud when the Mac cannot serve it. The two others pin it.
// `segments` shows all three glyphs with the chosen one lit; `cycle` is one button that shows the
// chosen glyph and steps to the next on a click.
import { useId, useState } from "react";
import { useT } from "../i18n";
import { Tooltip } from "../../../ui/Tooltip";
import type { HybridLook, HybridPin } from "./hybridModel";
import "./cloudToggle.css";

const ORDER = ["auto", "cloud", "local"] as const;
const NAMES = { auto: "hybrid.mode.hybrid", cloud: "hybrid.pin.cloud", local: "hybrid.pin.local" } as const;
const HELP = { auto: "hybrid.mode.hybrid.help", cloud: "hybrid.keepRunning.help", local: "hybrid.auto.help" } as const;

const CLOUD = "M4.6 12.5h7a2.6 2.6 0 0 0 .4-5.17A3.6 3.6 0 0 0 5.1 6.2 3.15 3.15 0 0 0 4.6 12.5Z";
const LAPTOP = "M3.5 4.5h9a1 1 0 0 1 1 1v5.5h-11V5.5a1 1 0 0 1 1-1ZM1.5 12.5h13";

/// One mode's glyph. Hybrid: the cloud's left half and the computer's right half, split by a slash.
function Glyph({ mode, paint }: { mode: HybridPin; paint: string }) {
  const clip = useId();
  return (
    <svg className="acpmux-hybrid-tri__glyph" data-mode={mode} width={16} height={16} viewBox="0 0 16 16" focusable="false" aria-hidden="true">
      <defs>
        <linearGradient id={paint} x1="2" y1="12" x2="14" y2="4" gradientUnits="userSpaceOnUse">
          <stop offset="0" className="acpmux-hybrid-stop" data-stop="1" />
          <stop offset="0.25" className="acpmux-hybrid-stop" data-stop="2" />
          <stop offset="0.5" className="acpmux-hybrid-stop" data-stop="3" />
          <stop offset="0.75" className="acpmux-hybrid-stop" data-stop="4" />
          <stop offset="1" className="acpmux-hybrid-stop" data-stop="5" />
        </linearGradient>
        <clipPath id={`${clip}a`}>
          <path d="M0 0h9.5L5.5 16H0Z" />
        </clipPath>
        <clipPath id={`${clip}b`}>
          <path d="M10.5 0H16v16H6.5Z" />
        </clipPath>
      </defs>
      {mode === "auto" ? (
        <>
          <path className="acpmux-hybrid-tri__cloud" d={CLOUD} clipPath={`url(#${CSS.escape(`${clip}a`)})`} />
          <path className="acpmux-hybrid-tri__laptop" d={LAPTOP} clipPath={`url(#${CSS.escape(`${clip}b`)})`} />
        </>
      ) : mode === "cloud" ? (
        <path className="acpmux-hybrid-tri__cloud" d={CLOUD} />
      ) : (
        <path className="acpmux-hybrid-tri__laptop" d={LAPTOP} />
      )}
    </svg>
  );
}

export function CloudTriToggle({
  pin,
  look = "rainbow",
  form = "segments",
  named = true,
  onChange,
}: {
  pin: HybridPin;
  look?: HybridLook;
  form?: "segments" | "cycle";
  /// Shows the chosen mode's name beside the glyphs.
  named?: boolean;
  onChange(pin: HybridPin): void;
}) {
  const t = useT();
  const paint = useId();
  const [fresh, setFresh] = useState(false);
  const pick = (next: HybridPin) => {
    setFresh(next !== pin);
    onChange(next);
  };
  const style = { "--acpmux-hybrid-paint": `url(#${CSS.escape(paint)})` } as React.CSSProperties;
  if (form === "cycle") {
    const next = ORDER[(ORDER.indexOf(pin) + 1) % ORDER.length]!;
    return (
      <Tooltip label={t(NAMES[pin])} detail={t(HELP[pin])} side="top">
        <button
          type="button"
          className="acpmux-hybrid-toggle acpmux-hybrid-tri"
          data-testid="hybrid-tri-toggle"
          data-look={look}
          data-form="cycle"
          data-mode={pin}
          data-fresh={fresh ? "" : undefined}
          aria-label={`${t("hybrid.pin")}: ${t(NAMES[pin])}`}
          style={style}
          onClick={() => pick(next)}
          onAnimationEnd={() => setFresh(false)}
        >
          <Glyph mode={pin} paint={paint} />
          {named && <span className="acpmux-hybrid-label">{t(NAMES[pin])}</span>}
        </button>
      </Tooltip>
    );
  }
  return (
    <span
      role="radiogroup"
      aria-label={t("hybrid.pin")}
      className="acpmux-hybrid-tri acpmux-hybrid-tri--segments"
      data-testid="hybrid-tri-toggle"
      data-look={look}
      data-mode={pin}
      style={style}
    >
      {ORDER.map((mode, index) => (
        <Tooltip key={mode} label={t(NAMES[mode])} detail={t(HELP[mode])} side="top">
          <button
            type="button"
            role="radio"
            aria-checked={mode === pin}
            aria-label={t(NAMES[mode])}
            tabIndex={mode === pin ? 0 : -1}
            className="acpmux-hybrid-toggle acpmux-hybrid-tri__segment"
            data-look={look}
            data-mode={mode}
            data-on={mode === pin ? "" : undefined}
            data-fresh={fresh && mode === pin ? "" : undefined}
            onClick={() => pick(mode)}
            onKeyDown={(event) => {
              const step = event.key === "ArrowRight" ? 1 : event.key === "ArrowLeft" ? -1 : 0;
              if (!step) return;
              event.preventDefault();
              pick(ORDER[(index + step + ORDER.length) % ORDER.length]!);
            }}
            onAnimationEnd={() => setFresh(false)}
          >
            <Glyph mode={mode} paint={`${paint}${mode === pin ? "" : mode}`} />
          </button>
        </Tooltip>
      ))}
      {named && <span className="acpmux-hybrid-label acpmux-hybrid-tri__name">{t(NAMES[pin])}</span>}
    </span>
  );
}
