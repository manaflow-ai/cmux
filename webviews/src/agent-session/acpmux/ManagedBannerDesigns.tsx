// l10n-allow-file: gallery design fixtures for the managed-chat line, not shipped UI.
// The line over the composer while another agent drives a chat, three ways, side by side in the
// gallery (Leo, 2026-11-03: "what does 'managing this chat' even mean? i feel like it's put out
// there too often"). Only `sending` ships (ManagedBanner.tsx); `driving` and `placeholder` exist
// here alone so the choice is made on what each looks like. `rows` runs the shipped rule
// (managedBy.ts `managerDrivingUntil`): a chat its manager only dispatched, or that went quiet,
// draws nothing.
import { Icon } from "./icons/Icon";
import { ManagedBanner } from "./ManagedBanner";
import { managerDrivingUntil, type ManagedBy, type PromptRow } from "./managedBy";
import "./managedBanner.css";

export type ManagedBannerDesign =
  | "sending"
  | "driving"
  | "placeholder"
  | "pill"
  | "pill-dot"
  | "pill-avatar"
  | "pill-straddle"
  | "pill-glass"
  | "pill-accent"
  | "pill-left"
  | "pill-mini"
  | "round-pill"
  | "round-soft"
  | "round-chip"
  | "round-tab";

export type ManagedBannerDesignsProps = {
  design: ManagedBannerDesign;
  manager: ManagedBy;
  /** The chat's rows, when the variant shows the rule rather than a design: no line unless the
   *  manager drives the chat at `now`. */
  rows?: readonly PromptRow[];
  now?: number;
};

const noop = () => undefined;

const pillDesigns = new Set<ManagedBannerDesign>([
  "pill",
  "pill-dot",
  "pill-avatar",
  "pill-straddle",
  "pill-glass",
  "pill-accent",
  "pill-left",
  "pill-mini",
]);

/// One roundness for the pill and the composer under it (Lawrence, 2026-11-26: "i dont like that these are
/// different roundness, make different variations"). The pill above was fully round over a composer with a
/// corner, two shapes in one place. Each of these sits on New Tab's one-card composer (Lucas, #57406:
/// the field on its own first row; +, the permissions and model chips, the mic and Send in one bar inside
/// the card), so it shows "lucas's recent work on variation 1 which puts permissions/model in the text input
/// area". Only the corner rule differs between them (managedBanner.css [data-round]).
const roundDesigns = new Set<ManagedBannerDesign>(["round-pill", "round-soft", "round-chip", "round-tab"]);

function OneCardComposer() {
  // A copy of the one card's layout for the gallery (newtab/screen.css "Unified Card"), not the
  // New Tab composer itself: the field's placeholder on the first row, one bar under it.
  return (
    <div className="acpmux-managed-card" aria-hidden="true">
      <div className="acpmux-managed-card-field">Ask anything</div>
      <div className="acpmux-managed-card-bar">
        <span className="acpmux-managed-card-round">
          <Icon name="composer.add" size={14} />
        </span>
        <span className="acpmux-managed-card-chip">
          <Icon name="permission.ask" size={13} />
          Ask permissions
        </span>
        <span className="acpmux-managed-card-chip">Opus 5.5</span>
        <span className="acpmux-managed-card-spacer" />
        <span className="acpmux-managed-card-round">
          <Icon name="media.audio" size={14} />
        </span>
        <span className="acpmux-managed-card-round acpmux-managed-card-send">
          <Icon name="composer.send" size={14} />
        </span>
      </div>
    </div>
  );
}

function RoundPair({ design, name }: { design: ManagedBannerDesign; name: string }) {
  return (
    <div className="acpmux-managed-round-stage" data-round={design}>
      <div className="acpmux-managed-round-pill">
        <button type="button" className="acpmux-managed-pill-open" title={`Open ${name}'s chat`}>
          <span className="acpmux-needs-you-dot acpmux-managed-pill-live" aria-hidden="true" />
          <span className="acpmux-managed-pill-text">
            <strong className="acpmux-managed-name">{name}</strong> is sending messages here
          </span>
        </button>
        <button type="button" className="acpmux-managed-pill-hide" aria-label="Hide" title="Hide">
          Hide
        </button>
      </div>
      <OneCardComposer />
    </div>
  );
}

/// Floating pill candidates (Lawrence, 2026-11-25: "make it more like a floating pill instead"). Each
/// is built from the pane's own floating pill: Jump to latest's glass (`ui-glass ui-glass-floats
/// acpmux-jump-latest`, conversation.css) widened as the Needs your input pill is
/// (`acpmux-needs-you-pill`, needsYou.css), with catalog icons (`agent.chief`, `action.close`,
/// `action.hide`) and the Needs you dot. Only the content and the lead mark differ.
function ManagedPill({ design, name }: { design: ManagedBannerDesign; name: string }) {
  // No icon (Lawrence, 2026-11-25: "get rid of the icon"). The whole pill is one button: a press
  // opens the chat that is sending (the Chief's, or the agent's that started this one), as the Jump
  // to latest pill goes where it says; a separate x at its end hides it. Hover washes the pill
  // (.acpmux-jump-latest:hover) and the x keeps its own hover, so the two targets read apart.
  const short = design === "pill-mini";
  const live = design === "pill-dot" || design === "pill-straddle";
  const hideWord = design === "pill" || design === "pill-glass" || design === "pill-accent" || design === "pill-left";
  return (
    <div className="acpmux-managed-pill-stage" data-design={design}>
      <div
        className="ui-glass ui-glass-floats acpmux-jump-latest acpmux-needs-you-pill acpmux-managed-pill"
        data-shown=""
        data-design={design}
      >
        <button type="button" className="acpmux-managed-pill-open" title={`Open ${name}'s chat`}>
          {live ? <span className="acpmux-needs-you-dot acpmux-managed-pill-live" aria-hidden="true" /> : null}
          <span className="acpmux-managed-pill-text">
            <strong className="acpmux-managed-name">{name}</strong>
            {short ? " is sending" : " is sending messages here"}
          </span>
        </button>
        <button type="button" className="acpmux-managed-pill-hide" aria-label="Hide" title="Hide">
          {hideWord ? "Hide" : "\u00d7"}
        </button>
      </div>
    </div>
  );
}

export function ManagedBannerDesigns({ design, manager, rows, now = Date.now() }: ManagedBannerDesignsProps) {
  if (rows) {
    const until = managerDrivingUntil(manager, rows);
    if (until === undefined || until <= now) return <div className="acpmux-managed-design-empty" data-shown="false" />;
  }
  const name = manager.kind === "chief" ? "Chief" : manager.name;
  if (roundDesigns.has(design)) return <RoundPair design={design} name={name} />;
  if (pillDesigns.has(design)) return <ManagedPill design={design} name={name} />;
  if (design === "sending") return <ManagedBanner manager={manager} onHide={noop} onOpenManager={noop} />;
  if (design === "driving")
    return (
      <output className="acpmux-managed-banner" data-design="driving">
        <span className="acpmux-managed-text">
          <strong className="acpmux-managed-name">{name}</strong> is driving this chat
        </span>
        <button type="button" className="acpmux-managed-take-over">
          Hide
        </button>
      </output>
    );
  return (
    <div className="acpmux-composer" data-design="placeholder">
      <div
        className="acpmux-composer-box"
        data-page-glass="a gallery design candidate drawn in place of the composer card, no glass of its own"
        style={{ padding: "12px 16px", color: "var(--acpmux-composer-placeholder)" }}
      >
        {name} is sending messages here. Type to reply as you
      </div>
    </div>
  );
}
