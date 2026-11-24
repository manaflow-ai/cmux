// Auto as where a new chat runs (autoWhereModel.ts): its icon in each look, and the arrival line that
// says where Auto put the chat and offers to bring it back. The words are the other rows' words
// ("Auto", one plain sentence); what makes Auto special is the icon, its colour and a little motion
// (autoWhere.css), which hold still under reduced motion.
import "./autoWhere.css";
import { useId } from "react";
import { useT } from "./i18n";
import { type AutoLanding, type AutoLook, landingMove, landingTextKey } from "./autoWhereModel";

/// Auto's icon. `split` (ships): half a computer, half a cloud, cut by an angled slash: this Mac or
/// Cloud. `orbit`: your chat as a still centre and three machine-coloured dots going
/// round it. `constellation`: a spark in the machines' colours. `aurora`: there-and-back arrows in a
/// cool gradient. `plain`: the arrows in the text colour, as any row's icon.
export function AutoIcon({ look }: { look: AutoLook }) {
  const className = "acpmux-icon acpmux-location-icon acpmux-env-icon ui-ghost-icon acpmux-auto-icon";
  if (look === "split") return <SplitIcon className={className} />;
  if (look === "orbit") {
    return (
      <svg
        className={className}
        data-look={look}
        width={14}
        height={14}
        viewBox="0 0 16 16"
        fill="none"
        aria-hidden="true"
        focusable="false"
      >
        <circle cx="8" cy="8" r="5.25" stroke="currentColor" strokeWidth={1} opacity={0.35} />
        <circle cx="8" cy="8" r="1.6" fill="currentColor" />
        <g className="acpmux-auto-orbit">
          <circle cx="8" cy="2.75" r="1.5" fill="var(--agent-ansi-4, currentColor)" />
          <circle cx="12.55" cy="10.6" r="1.5" fill="var(--agent-ansi-2, currentColor)" />
          <circle cx="3.45" cy="10.6" r="1.5" fill="var(--agent-ansi-5, currentColor)" />
        </g>
      </svg>
    );
  }
  if (look === "constellation") {
    return (
      <svg
        className={className}
        data-look={look}
        width={14}
        height={14}
        viewBox="0 0 16 16"
        aria-hidden="true"
        focusable="false"
      >
        <defs>
          <linearGradient id="acpmux-auto-spark" x1="2" y1="2" x2="14" y2="14" gradientUnits="userSpaceOnUse">
            <stop offset="0" stopColor="var(--agent-ansi-5, currentColor)" />
            <stop offset="0.55" stopColor="var(--agent-ansi-4, currentColor)" />
            <stop offset="1" stopColor="var(--agent-ansi-6, currentColor)" />
          </linearGradient>
        </defs>
        <path
          className="acpmux-auto-spark"
          fill="url(#acpmux-auto-spark)"
          d="M7 1.5c.35 2.9 1.6 4.15 4.5 4.5-2.9.35-4.15 1.6-4.5 4.5C6.65 7.6 5.4 6.35 2.5 6c2.9-.35 4.15-1.6 4.5-4.5Z"
        />
        <path
          className="acpmux-auto-spark-small"
          fill="var(--agent-ansi-6, currentColor)"
          d="M12 9.5c.18 1.45.8 2.07 2.25 2.25-1.45.18-2.07.8-2.25 2.25-.18-1.45-.8-2.07-2.25-2.25 1.45-.18 2.07-.8 2.25-2.25Z"
        />
      </svg>
    );
  }
  const aurora = look === "aurora";
  return (
    <svg
      className={className}
      data-look={look}
      width={14}
      height={14}
      viewBox="0 0 16 16"
      fill="none"
      stroke={aurora ? "url(#acpmux-auto-aurora)" : "currentColor"}
      strokeWidth={aurora ? 1.4 : 1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {aurora && (
        <defs>
          <linearGradient id="acpmux-auto-aurora" x1="0" y1="0" x2="16" y2="16" gradientUnits="userSpaceOnUse">
            <stop offset="0" stopColor="var(--agent-ansi-6, currentColor)" />
            <stop offset="0.5" stopColor="var(--agent-ansi-4, currentColor)" />
            <stop offset="1" stopColor="var(--agent-ansi-5, currentColor)" />
          </linearGradient>
        </defs>
      )}
      <path d="M2.5 6h9l-2.5-2.5M13.5 10h-9l2.5 2.5" />
    </svg>
  );
}

/// The `split` look: the computer's left half and the cloud's right half, each clipped to its side of
/// one slash from top right to bottom left, with a hairline gap either side of the slash.
function SplitIcon({ className }: { className: string }) {
  const id = useId();
  const computer = `${id}-computer`;
  const cloud = `${id}-cloud`;
  return (
    <svg
      className={className}
      data-look="split"
      width={14}
      height={14}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <defs>
        <clipPath id={computer}>
          <path d="M0 0h9.6L3.6 16H0Z" />
        </clipPath>
        <clipPath id={cloud}>
          <path d="M12.4 0H16v16H6.4Z" />
        </clipPath>
      </defs>
      <g clipPath={`url(#${computer})`}>
        <rect x="1.75" y="3" width="11" height="7.75" rx="1.25" />
        <path d="M1 13.25h11" />
      </g>
      <path
        className="acpmux-auto-split-cloud"
        clipPath={`url(#${cloud})`}
        stroke="var(--agent-ansi-4, currentColor)"
        d="M5.4 13.25h6.85a3.05 3.05 0 0 0 .55-6.05A4.25 4.25 0 0 0 5.2 6.1a3.6 3.6 0 0 0 .2 7.15Z"
      />
      <path className="acpmux-auto-split-slash" d="M12 1.5 4 14.5" />
    </svg>
  );
}

/// The line under an Auto chat's first message: where it went, and the move back (Bring it back from
/// Cloud; Move to Cloud from here). `deciding`: Send asked the daemon and it has not answered yet.
export function AutoArrival({
  landing,
  look,
  onMove,
  onDismiss,
}: {
  landing: AutoLanding | "deciding";
  look: AutoLook;
  /// The chat's own move (App.tsx `offloadChat`); none: the line offers no move.
  onMove?(kind: "bringBack" | "move"): void;
  onDismiss?(): void;
}) {
  const t = useT();
  const deciding = landing === "deciding";
  const move = deciding ? undefined : landingMove(landing);
  return (
    <div
      className="acpmux-auto-arrival"
      data-auto-look={look}
      data-went={deciding ? "deciding" : landing.went}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a flex row in the notices strip; <output> is inline and form-bound.
      role="status"
      title={deciding ? undefined : landing.why}
    >
      <AutoIcon look={look} />
      <span className="acpmux-auto-arrival-text">{deciding ? t("auto.deciding") : t(landingTextKey(landing))}</span>
      {move && onMove && (
        <button type="button" className="acpmux-auto-arrival-move ui-ghost ui-ghost-sm" onClick={() => onMove(move)}>
          {t(move === "bringBack" ? "auto.bringBack" : "composer.moveToCloud")}
        </button>
      )}
      {!deciding && onDismiss && (
        <button
          type="button"
          className="acpmux-auto-arrival-dismiss ui-ghost ui-ghost-sm"
          aria-label={t("auto.dismiss")}
          onClick={onDismiss}
        >
          <svg
            className="ui-ghost-icon"
            width={12}
            height={12}
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            strokeWidth={1.5}
            strokeLinecap="round"
            aria-hidden="true"
            focusable="false"
          >
            <path d="m4.5 4.5 7 7m0-7-7 7" />
          </svg>
        </button>
      )}
    </div>
  );
}

/// The one-shot line shown while Auto's scale-up admission starts a machine. It uses the arrival
/// line's existing Auto styling; the model decides whether the text is present.
export function AutoAddingMachineLine({ text, look }: { text: string; look: AutoLook }) {
  return (
    <div className="acpmux-auto-arrival" data-auto-look={look} data-went="scalingUp" role="status">
      <AutoIcon look={look} />
      <span className="acpmux-auto-arrival-text">{text}</span>
    </div>
  );
}
