// l10n-allow-file: gallery fixtures and design captions (candidate looks), not shipped copy.
//
// Auto as a Where choice, beside This Mac, Cloud and the account's machines: how it could look. Leo,
// 2026-11-22: "AUTO SHOULD LOOK BETTER. MAKE IT FUCKING LOOK SPECIAL. BUT CONSSITENT TEXT-WISE. BUT
// MAKE IT FLAVOURFUL. TASTEFUL BUT FUCKING EXCITING. ... IF YOU TOGGLE IT ON IN THE UI, BOOM. WHO KNOWS
// WHERE YOUR AGENT WILL BE!? BUT IT DOESN'T MATTER, BECAUSE YOU CAN BRING IT BACK TO YOU OR BACK TO
// CLOUD OR BACK TO ANOTHER MACHINE THAT IS UNDER YOUR JURISTICTION."
//
// Looks only: every board is drawn from the Where chip's and its menu's own classes (EnvironmentPicker,
// composerLocation.css) with no picker behind it, so a candidate can be judged without changing what
// a pick does. The text is the other rows' text: one line, the same size and weight ("Auto" as "This
// Mac" and "Cloud"); the difference is the icon, its colour, a little motion and a short muted hint on
// the same line (the picker keeps no second lines, Leo 2026-10-31). Motion stops under reduced motion.
import type { ReactNode } from "react";
import { componentEntry } from "../../gallery/format";
import { EnvironmentIcon } from "./EnvironmentPicker";

type Look = "plain" | "constellation" | "orbit" | "aurora";

type Props = {
  /// The candidate: `plain` is Auto drawn like any other row (the baseline), the rest are looks.
  look: Look;
};

/// Each look's short hint, on Auto's own line after its name.
const HINTS: Record<Look, string> = {
  plain: "",
  constellation: "Best place",
  orbit: "Cloud now",
  aurora: "Bring back any time",
};

/// The account's other machine, in its identity colour (machineColor).
const MACHINE = "build box";

function AutoIcon({ look }: { look: Look }) {
  if (look === "orbit") {
    // A centre that stays (your chat) and three machine-coloured dots going round it.
    return (
      <svg
        className="acpmux-icon acpmux-location-icon acpmux-env-icon ui-ghost-icon auto-env-icon"
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
        <g className="auto-env-orbit">
          <circle cx="8" cy="2.75" r="1.5" fill="var(--agent-ansi-4, currentColor)" />
          <circle cx="12.55" cy="10.6" r="1.5" fill="var(--agent-ansi-2, currentColor)" />
          <circle cx="3.45" cy="10.6" r="1.5" fill="var(--agent-ansi-5, currentColor)" />
        </g>
      </svg>
    );
  }
  if (look === "aurora") {
    // Two arrows that leave and come back: it goes anywhere, and it comes back.
    return (
      <svg
        className="acpmux-icon acpmux-location-icon acpmux-env-icon ui-ghost-icon auto-env-icon"
        data-look={look}
        width={14}
        height={14}
        viewBox="0 0 16 16"
        fill="none"
        stroke="url(#auto-env-aurora)"
        strokeWidth={1.4}
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden="true"
        focusable="false"
      >
        <defs>
          <linearGradient id="auto-env-aurora" x1="0" y1="0" x2="16" y2="16" gradientUnits="userSpaceOnUse">
            <stop offset="0" stopColor="var(--agent-ansi-6, currentColor)" />
            <stop offset="0.5" stopColor="var(--agent-ansi-4, currentColor)" />
            <stop offset="1" stopColor="var(--agent-ansi-5, currentColor)" />
          </linearGradient>
        </defs>
        <path d="M2.5 6h9l-2.5-2.5M13.5 10h-9l2.5 2.5" />
      </svg>
    );
  }
  if (look === "constellation") {
    // A four-point spark with a small one beside it, in the machines' colours.
    return (
      <svg
        className="acpmux-icon acpmux-location-icon acpmux-env-icon ui-ghost-icon auto-env-icon"
        data-look={look}
        width={14}
        height={14}
        viewBox="0 0 16 16"
        aria-hidden="true"
        focusable="false"
      >
        <defs>
          <linearGradient id="auto-env-spark" x1="2" y1="2" x2="14" y2="14" gradientUnits="userSpaceOnUse">
            <stop offset="0" stopColor="var(--agent-ansi-5, currentColor)" />
            <stop offset="0.55" stopColor="var(--agent-ansi-4, currentColor)" />
            <stop offset="1" stopColor="var(--agent-ansi-6, currentColor)" />
          </linearGradient>
        </defs>
        <path
          className="auto-env-spark"
          fill="url(#auto-env-spark)"
          d="M7 1.5c.35 2.9 1.6 4.15 4.5 4.5-2.9.35-4.15 1.6-4.5 4.5C6.65 7.6 5.4 6.35 2.5 6c2.9-.35 4.15-1.6 4.5-4.5Z"
        />
        <path
          className="auto-env-spark-small"
          fill="var(--agent-ansi-6, currentColor)"
          d="M12 9.5c.18 1.45.8 2.07 2.25 2.25-1.45.18-2.07.8-2.25 2.25-.18-1.45-.8-2.07-2.25-2.25 1.45-.18 2.07-.8 2.25-2.25Z"
        />
      </svg>
    );
  }
  // The baseline: a plain glyph in the text colour, as any other row's.
  return (
    <svg
      className="acpmux-icon acpmux-location-icon acpmux-env-icon ui-ghost-icon"
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
      <path d="M2.5 6h9l-2.5-2.5M13.5 10h-9l2.5 2.5" />
    </svg>
  );
}

function Check() {
  return (
    <svg
      className="acpmux-icon"
      width={12}
      height={12}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="m3.5 8.5 3 3 6-7" />
    </svg>
  );
}

function Chevron() {
  return (
    <span className="ui-ghost-icon" aria-hidden="true">
      <svg
        className="acpmux-icon"
        width={10}
        height={10}
        viewBox="0 0 16 16"
        fill="none"
        stroke="currentColor"
        strokeWidth={1.5}
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden="true"
        focusable="false"
      >
        <path d="m4 6 4 4 4-4" />
      </svg>
    </span>
  );
}

/// The Where chip, closed: Auto picked (with its look) or This Mac.
function Chip({ look, pick, hover }: { look: Look; pick: "auto" | "local"; hover?: boolean }) {
  const auto = pick === "auto";
  return (
    <span
      className="acpmux-location-picker"
      data-kind="computer"
      data-face="label"
      data-auto-look={auto ? look : undefined}
    >
      <button
        type="button"
        className="acpmux-location-button ui-ghost ui-ghost-sm"
        data-gallery-hover={hover ? "" : undefined}
        aria-label={`Environment: ${auto ? "Auto" : "This Mac"}`}
      >
        {auto ? <AutoIcon look={look} /> : <EnvironmentIcon kind="local" />}
        <span className="acpmux-location-label">{auto ? "Auto" : "This Mac"}</span>
        <Chevron />
      </button>
    </span>
  );
}

type RowProps = { icon: ReactNode; name: string; hint?: string; checked?: boolean; highlighted?: boolean; auto?: Look };

function Row({ icon, name, hint, checked, highlighted, auto }: RowProps) {
  return (
    <div
      className="acpmux-menu-item"
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- mirrors the live menu row.
      role="option"
      aria-selected={checked}
      data-highlighted={highlighted ? "" : undefined}
    >
      <span
        className="acpmux-location-row acpmux-env-row"
        data-auto-look={auto}
        data-current={checked ? "" : undefined}
      >
        {icon}
        <span className="acpmux-menu-text acpmux-location-name">
          <span className="acpmux-menu-label">{name}</span>
        </span>
        {hint ? <span className="acpmux-env-state auto-env-hint">{hint}</span> : null}
        <span className="acpmux-location-check" aria-hidden="true">
          {checked && <Check />}
        </span>
      </span>
    </div>
  );
}

/// The Where menu, open: Auto first, then This Mac, Cloud and another machine, one line each.
function Menu({ look, pick, hoverAuto }: { look: Look; pick: "auto" | "local"; hoverAuto?: boolean }) {
  return (
    <div
      className="acpmux-menu acpmux-location-menu acpmux-folder-popover acpmux-env-popover acpmux-env-searchless auto-env-menu"
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- mirrors the live Where menu.
      role="listbox"
    >
      <div className="acpmux-env-heading">Where should this chat run?</div>
      <Row
        icon={<AutoIcon look={look} />}
        name="Auto"
        hint={HINTS[look]}
        checked={pick === "auto"}
        highlighted={hoverAuto}
        auto={look}
      />
      <Row
        icon={<EnvironmentIcon kind="local" />}
        name="This Mac"
        checked={pick === "local"}
        highlighted={!hoverAuto && pick === "local"}
      />
      <Row icon={<EnvironmentIcon kind="cloud" />} name="Cloud" />
      <Row icon={<EnvironmentIcon kind="ssh" name={MACHINE} />} name={MACHINE} />
    </div>
  );
}

function Cell({ caption, children }: { caption: string; children: ReactNode }) {
  return (
    <figure className="auto-env-cell">
      <figcaption>{caption}</figcaption>
      <div className="auto-env-cell-body">{children}</div>
    </figure>
  );
}

/// One look on one board: the chip closed (picked, hovered, not picked) and the menu open (Auto
/// picked; Auto hovered while This Mac is picked).
function Board({ look }: Props) {
  return (
    <div className="auto-env-board" data-look={look}>
      <div className="auto-env-chips">
        <Cell caption="Chip · Auto picked">
          <Chip look={look} pick="auto" />
        </Cell>
        <Cell caption="Chip · hover">
          <Chip look={look} pick="auto" hover />
        </Cell>
        <Cell caption="Chip · This Mac picked">
          <Chip look={look} pick="local" />
        </Cell>
      </div>
      <div className="auto-env-menus">
        <Cell caption="Menu · Auto picked">
          <Menu look={look} pick="auto" />
        </Cell>
        <Cell caption="Menu · hover on Auto">
          <Menu look={look} pick="local" hoverAuto />
        </Cell>
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.auto-environment-looks",
  title: "Auto environment looks",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/EnvironmentPicker.tsx#EnvironmentIcon"],
  styles: () =>
    Promise.all([
      import("./styles.css"),
      import("./composerLocation.css"),
      import("./AutoEnvironmentLooks.gallery.css"),
    ]),
  load: async () => Board,
  widths: { normal: 620, wide: 760 },
  height: 360,
  anchors: [{ selector: ".auto-env-board" }],
  variants: {
    plain: {
      note: "Baseline: Auto drawn as any other row, a plain glyph in the text colour, no hint. What every look is measured against.",
      props: { look: "plain" },
    },
    constellation: {
      note: "Constellation: a spark in the machines' colours (the terminal palette machineColor draws machines in) that twinkles once on hover and slowly breathes while Auto is picked. Hint: Best place.",
      props: { look: "constellation" },
    },
    orbit: {
      note: "Orbit: your chat as a still centre with three machine-coloured dots going round it, about one turn in 6 s while Auto is picked and quicker on hover. Hint names where it would land now: Cloud now.",
      props: { look: "orbit" },
    },
    aurora: {
      note: "Aurora: there-and-back arrows in a cool gradient, with a soft gradient wash that drifts under the Auto row and a hairline under the chip. Hint: Bring back any time.",
      props: { look: "aurora" },
    },
  },
});
