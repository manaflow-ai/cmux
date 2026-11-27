// The three-state cloud control (Leo, 2026-11-23 11:08Z: "we can potentially have a split cloud /
// computer looking button, then full cloud, then only computer"). Hybrid is the default: the chat
// runs on this Mac and continues in Cloud when the Mac cannot serve it. The two others pin it.
// `segments` shows all three glyphs with the chosen one lit; `cycle` is one button that shows the
// chosen glyph and steps to the next on a click.
import { DisclosureFace } from "../DisclosureFace";
import { useId, useState } from "react";
import { useT } from "../i18n";
import { Tooltip } from "../../../ui/Tooltip";
import { Menu, MenuButton, MenuGroup, MenuItem, MenuPopup } from "../../../ui/Menu";
import type {
  HybridBlocked,
  HybridBlockedWhy,
  HybridLook,
  HybridPin,
  SlotHolder,
  HybridStart,
  HybridStartState,
} from "./hybridModel";
import "./cloudToggle.css";

const ORDER = ["auto", "cloud", "local"] as const;
const NAMES = { auto: "hybrid.mode.hybrid", cloud: "hybrid.pin.cloud", local: "hybrid.pin.local" } as const;
const HELP = {
  auto: "hybrid.mode.hybrid.help",
  cloud: "hybrid.pin.cloud.help",
  local: "hybrid.pin.local.help",
} as const;

/// A blocked control's name and its tooltip (what a click does). Labels only: no price, no refusal.
const BLOCKED = {
  "signed-out": "hybrid.blocked.signed-out",
  "no-plan": "hybrid.blocked.no-plan",
  "no-cloud": "hybrid.blocked.no-cloud",
  "hours-spent": "hybrid.blocked.hours-spent",
  "trial-ended": "hybrid.blocked.trial-ended",
  offline: "hybrid.blocked.offline",
  "move-failed": "hybrid.blocked.move-failed",
  slept: "hybrid.blocked.slept",
  "trial-full": "hybrid.blocked.trial-full",
} as const satisfies Record<HybridBlockedWhy, string>;
const BLOCKED_HELP = {
  "signed-out": "hybrid.blocked.signed-out.help",
  "no-plan": "hybrid.blocked.no-plan.help",
  "no-cloud": "hybrid.blocked.no-cloud.help",
  "hours-spent": "hybrid.blocked.hours-spent.help",
  "trial-ended": "hybrid.blocked.trial-ended.help",
  offline: "hybrid.blocked.offline.help",
  "move-failed": "hybrid.blocked.move-failed.help",
  slept: "hybrid.blocked.slept.help",
  "trial-full": "hybrid.blocked.trial-full.help",
} as const satisfies Record<HybridBlockedWhy, string>;
/// A hybrid start's state, as the control's name and its tooltip (RFD 0078 "the start"; rule 2: the
/// button alone shows it, no dialog, no banner).
const START = {
  booting: "hybrid.start.booting",
  ready: "hybrid.start.ready",
  moving: "hybrid.start.moving",
  live: "hybrid.start.live",
  failed: "hybrid.start.failed",
} as const satisfies Record<HybridStartState, string>;
const START_HELP = {
  booting: "hybrid.start.booting.help",
  ready: "hybrid.start.ready.help",
  moving: "hybrid.start.moving.help",
  live: "hybrid.start.live.help",
  failed: "hybrid.start.failed.help",
} as const satisfies Record<HybridStartState, string>;
/// The machine is up (or the chat is on it): the cloud takes its color.
const START_LIT: ReadonlySet<HybridStartState> = new Set(["ready", "moving", "live"]);

/// The two that are failures, not setup: they alone wear the warning dot.
const FAILURE: ReadonlySet<HybridBlockedWhy> = new Set(["offline", "move-failed"]);

const CLOUD = "M4.6 12.5h7a2.6 2.6 0 0 0 .4-5.17A3.6 3.6 0 0 0 5.1 6.2 3.15 3.15 0 0 0 4.6 12.5Z";
const LAPTOP = "M3.5 4.5h9a1 1 0 0 1 1 1v5.5h-11V5.5a1 1 0 0 1 1-1ZM1.5 12.5h13";

/// One mode's glyph. Hybrid: the cloud's left half and the computer's right half, split by a slash.
function Glyph({ mode, paint }: { mode: HybridPin; paint: string }) {
  const clip = useId();
  return (
    <svg
      className="acpmux-hybrid-tri__glyph"
      data-mode={mode}
      width={mode === "auto" ? 22 : 16}
      height={16}
      viewBox={mode === "auto" ? "0 0 22 16" : "0 0 16 16"}
      focusable="false"
      aria-hidden="true"
    >
      <defs>
        <linearGradient id={paint} x1="2" y1="12" x2="14" y2="4" gradientUnits="userSpaceOnUse">
          <stop offset="0" className="acpmux-hybrid-stop" data-stop="1" />
          <stop offset="0.25" className="acpmux-hybrid-stop" data-stop="2" />
          <stop offset="0.5" className="acpmux-hybrid-stop" data-stop="3" />
          <stop offset="0.75" className="acpmux-hybrid-stop" data-stop="4" />
          <stop offset="1" className="acpmux-hybrid-stop" data-stop="5" />
        </linearGradient>
        <clipPath id={`${clip}a`}>
          <path d="M0 0h10.5L7.5 16H0Z" />
        </clipPath>
        <clipPath id={`${clip}b`}>
          <path d="M6 0h10v16H3Z" />
        </clipPath>
      </defs>
      {mode === "auto" ? (
        <>
          <path className="acpmux-hybrid-tri__cloud" d={CLOUD} clipPath={`url(#${CSS.escape(`${clip}a`)})`} />
          <g transform="translate(6 0)">
            <path className="acpmux-hybrid-tri__laptop" d={LAPTOP} clipPath={`url(#${CSS.escape(`${clip}b`)})`} />
          </g>
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
  lit = false,
  waiting = false,
  blocked,
  onBlockedClick,
  holders,
  onTrade,
  holdersOpen = false,
  where,
  start,
  onChange,
  onLitChange,
}: {
  pin: HybridPin;
  look?: HybridLook;
  form?: "segments" | "cycle";
  /// Shows the chosen mode's name beside the glyphs.
  named?: boolean;
  /// Hybrid only: the chat is high priority (Keep Running), so the split glyph's cloud half is lit.
  /// Only in Cloud is always lit; Only on This Mac never is.
  lit?: boolean;
  /// Hybrid only: the person asked for Keep Running and every slot is taken. The name says so,
  /// because a tooltip alone is invisible (first-run finding, 2026-11-23).
  waiting?: boolean;
  /// The app says the place cannot change now (signed out, no plan, offline...). The name says
  /// which, the cloud is dull, and every click goes to `onBlockedClick` instead of `onChange`.
  /// The app decides which applies; the control only draws it. `slept` is the one exception: its
  /// click turns on Keep Running (`onLitChange(true)`), as its tooltip says.
  blocked?: HybridBlocked;
  onBlockedClick?(why: HybridBlockedWhy): void;
  /// Every slot is taken (priority.rs `Admit::Full { holders }`): the name opens a menu of the
  /// chats holding them, each with a row that trades its slot to this chat (`onTrade`).
  holders?: readonly SlotHolder[];
  onTrade?(session: string): void;
  /// The holders' menu opens drawn (the gallery's still).
  holdersOpen?: boolean;
  /// Where the chat runs right now, from the app's place state ("This Mac", the Cloud machine's
  /// name, "Moving to ..."): drawn after the name, so turning Hybrid on shows what it did.
  where?: string;
  /// A hybrid start (Cloud chosen, the chat started here while its machine boots): the name says
  /// which step, the chosen glyph shows it (breathing while it boots, a sweep while it moves, the
  /// warning dot when it failed and the chat stays here). Blocked wins over it; a pick still works.
  start?: HybridStart;
  onChange(pin: HybridPin): void;
  /// Choosing Hybrid again while it is chosen turns its light on or off.
  onLitChange?(lit: boolean): void;
}) {
  const t = useT();
  const paint = useId();
  const [fresh, setFresh] = useState(false);
  const [menuOpen, setMenuOpen] = useState(holdersOpen);
  const why = blocked?.why;
  const step = why ? undefined : start?.cloud;
  const glows = (mode: HybridPin) =>
    !why && (step ? mode === pin && START_LIT.has(step) : mode === "cloud" || (mode === "auto" && lit));
  const failed = (why !== undefined && FAILURE.has(why)) || step === "failed";
  // The warning dot sits on the chosen glyph when it shows the cloud, else on Only in Cloud's.
  const dotOn: HybridPin = pin === "local" ? "cloud" : pin;
  const dot = <span className="acpmux-hybrid-tri__dot" aria-hidden="true" />;
  const startTip = (state: HybridStartState) => ({
    label: t(START[state]),
    // Rust's reason first: it says what failed; the sentence after says the chat is still here.
    detail: state === "failed" && start?.reason ? `${start.reason} ${t(START_HELP[state])}` : t(START_HELP[state]),
    className: "ui-card",
  });
  const tip = (mode: HybridPin) =>
    why
      ? // A hover card, so the sentence saying what a click does shows (a plain tooltip is one line).
        { label: t(BLOCKED[why]), detail: t(BLOCKED_HELP[why]), className: "ui-card" }
      : step && mode === pin
        ? startTip(step)
        : { label: t(NAMES[mode]), detail: t(HELP[mode]) };
  const blockedClick = (blockedWhy: HybridBlockedWhy) => {
    if (blockedWhy === "slept") {
      if (!onLitChange) return;
      setFresh(true);
      onLitChange(true);
      return;
    }
    onBlockedClick?.(blockedWhy);
  };
  const pick = (next: HybridPin) => {
    if (why) {
      blockedClick(why);
      return;
    }
    if (next === pin) {
      if (pin !== "auto" || !onLitChange) return;
      setFresh(!lit);
      onLitChange(!lit);
      return;
    }
    setFresh(glows(next));
    onChange(next);
  };
  const name = step
    ? t(START[step])
    : pin === "auto" && waiting
      ? t("hybrid.waiting.label")
      : pin === "auto" && lit
        ? t("hybrid.keepRunning")
        : t(NAMES[pin]);
  const style = { "--acpmux-hybrid-paint": `url(#${CSS.escape(paint)})` } as React.CSSProperties;
  if (form === "cycle") {
    const next = ORDER[(ORDER.indexOf(pin) + 1) % ORDER.length]!;
    return (
      <Tooltip {...tip(pin)} side="top">
        <button
          type="button"
          className="acpmux-hybrid-toggle acpmux-hybrid-tri"
          data-testid="hybrid-tri-toggle"
          data-look={look}
          data-form="cycle"
          data-mode={pin}
          data-blocked={why}
          data-start={step}
          data-lit={glows(pin) ? "" : undefined}
          data-fresh={fresh ? "" : undefined}
          aria-label={`${t("hybrid.pin")}: ${why ? t(BLOCKED[why]) : step ? t(START[step]) : t(NAMES[pin])}`}
          style={style}
          onClick={() => pick(next)}
          onAnimationEnd={() => setFresh(false)}
        >
          <Glyph mode={pin} paint={paint} />
          {failed && dot}
          {named && (
            <span className="acpmux-hybrid-label">{why ? t(BLOCKED[why]) : step ? t(START[step]) : t(NAMES[pin])}</span>
          )}
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
      data-blocked={why}
      data-start={step}
      style={style}
    >
      {ORDER.map((mode, index) => (
        <Tooltip key={mode} {...tip(mode)} side="top">
          <button
            type="button"
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a segment holds a glyph and a tooltip, which an input cannot.
            role="radio"
            aria-checked={mode === pin}
            // Blocked, every segment runs the blocked action, so each says that action, not its mode.
            aria-label={why ? t(BLOCKED[why]) : t(NAMES[mode])}
            tabIndex={mode === pin ? 0 : -1}
            className="acpmux-hybrid-toggle acpmux-hybrid-tri__segment"
            data-look={look}
            data-mode={mode}
            data-on={mode === pin ? "" : undefined}
            data-lit={mode === pin && glows(mode) ? "" : undefined}
            data-fresh={fresh && mode === pin ? "" : undefined}
            data-blocked={why}
            data-start={mode === pin ? step : undefined}
            data-waiting={mode === pin && mode === "auto" && waiting ? "" : undefined}
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
            {failed && mode === dotOn && dot}
          </button>
        </Tooltip>
      ))}
      {named && why && (
        <Tooltip {...tip(pin)} side="top">
          <button
            type="button"
            className="acpmux-hybrid-toggle acpmux-hybrid-label acpmux-hybrid-tri__name"
            data-blocked={why}
            onClick={() => blockedClick(why)}
          >
            {t(BLOCKED[why])}
          </button>
        </Tooltip>
      )}
      {named && step && (
        <Tooltip {...startTip(step)} side="top">
          <span className="acpmux-hybrid-label acpmux-hybrid-tri__name" data-testid="hybrid-start" data-start={step}>
            {name}
            {where && (
              <span className="acpmux-hybrid-tri__where" data-testid="hybrid-where">
                {where}
              </span>
            )}
          </span>
        </Tooltip>
      )}
      {named && !why && !step && holders && holders.length > 0 && (
        <Menu open={menuOpen} onOpenChange={setMenuOpen}>
          <MenuButton
            className="acpmux-hybrid-toggle acpmux-hybrid-label acpmux-hybrid-tri__name"
            label={t("hybrid.holders.label")}
            data-menu="Slots"
          >
            <DisclosureFace>{name}</DisclosureFace>
          </MenuButton>
          <MenuPopup className="acpmux-menu acpmux-hybrid-holders" label={t("hybrid.holders.label")} side="top">
            <MenuGroup label={t("hybrid.holders.label")}>
              {holders.map((holder) => (
                <MenuItem key={holder.session} onSelect={() => onTrade?.(holder.session)}>
                  <span className="acpmux-hybrid-holder">
                    <span className="acpmux-hybrid-holder__title">{holder.title}</span>
                    <span className="acpmux-hybrid-holder__trade">{t("hybrid.holders.trade")}</span>
                  </span>
                </MenuItem>
              ))}
            </MenuGroup>
          </MenuPopup>
        </Menu>
      )}
      {named && !why && !step && !(holders && holders.length > 0) && (
        <span className="acpmux-hybrid-label acpmux-hybrid-tri__name">
          {name}
          {where && (
            <span className="acpmux-hybrid-tri__where" data-testid="hybrid-where">
              {where}
            </span>
          )}
        </span>
      )}
    </span>
  );
}
