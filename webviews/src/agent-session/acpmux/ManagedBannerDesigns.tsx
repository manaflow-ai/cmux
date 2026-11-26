// l10n-allow-file: gallery design fixtures for the managed-chat line, not shipped UI.
// The line over the composer while another agent drives a chat, three ways, side by side in the
// gallery (Leo, 2026-11-03: "what does 'managing this chat' even mean? i feel like it's put out
// there too often"). Only `sending` ships (ManagedBanner.tsx); `driving` and `placeholder` exist
// here alone so the choice is made on what each looks like. `rows` runs the shipped rule
// (managedBy.ts `managerDrivingUntil`): a chat its manager only dispatched, or that went quiet,
// draws nothing.
import { ManagedBanner } from "./ManagedBanner";
import { Icon } from "./icons/Icon";
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
  | "pill-mini";

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

/// Floating pill candidates (Lawrence, 2026-11-25: "make it more like a floating pill instead"). Each
/// is built from the pane's own floating pill: Jump to latest's glass (`ui-glass ui-glass-floats
/// acpmux-jump-latest`, conversation.css) widened as the Needs your input pill is
/// (`acpmux-needs-you-pill`, needsYou.css), with catalog icons (`agent.chief`, `action.close`,
/// `action.hide`) and the Needs you dot. Only the content and the lead mark differ.
function ManagedPill({ design, name }: { design: ManagedBannerDesign; name: string }) {
  const short = design === "pill-mini";
  const lead =
    design === "pill-dot" || design === "pill-straddle" ? (
      <span className="acpmux-needs-you-dot acpmux-managed-pill-live" aria-hidden="true" />
    ) : design === "pill" || design === "pill-glass" ? null : (
      <Icon name="agent.chief" size={14} />
    );
  const iconHide = design !== "pill" && design !== "pill-glass" && design !== "pill-accent" && design !== "pill-left";
  return (
    <div className="acpmux-managed-pill-stage" data-design={design}>
      <output
        className="ui-glass ui-glass-floats acpmux-jump-latest acpmux-needs-you-pill acpmux-managed-pill"
        data-shown=""
        data-design={design}
      >
        {lead}
        <span className="acpmux-managed-pill-text">
          <strong className="acpmux-managed-name">{name}</strong>
          {short ? " is sending" : " is sending messages here"}
        </span>
        <button type="button" className="acpmux-managed-take-over" aria-label="Hide" title="Hide">
          <Icon name={iconHide ? "action.close" : "action.hide"} size={12} />
          {iconHide ? null : <span>Hide</span>}
        </button>
      </output>
    </div>
  );
}

export function ManagedBannerDesigns({ design, manager, rows, now = Date.now() }: ManagedBannerDesignsProps) {
  if (rows) {
    const until = managerDrivingUntil(manager, rows);
    if (until === undefined || until <= now) return <div className="acpmux-managed-design-empty" data-shown="false" />;
  }
  const name = manager.kind === "chief" ? "Chief" : manager.name;
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
