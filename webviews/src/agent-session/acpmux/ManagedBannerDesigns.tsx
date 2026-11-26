// l10n-allow-file: gallery design fixtures for the managed-chat line, not shipped UI.
// The line over the composer while another agent drives a chat, three ways, side by side in the
// gallery (Leo, 2026-11-03: "what does 'managing this chat' even mean? i feel like it's put out
// there too often"). Only `sending` ships (ManagedBanner.tsx); `driving` and `placeholder` exist
// here alone so the choice is made on what each looks like. `rows` runs the shipped rule
// (managedBy.ts `managerDrivingUntil`): a chat its manager only dispatched, or that went quiet,
// draws nothing.
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

/// Floating pill candidates (Lawrence, 2026-11-25: "make it more like a floating pill instead"): the
/// line becomes a rounded chip that floats over the composer's top edge instead of a full-width row.
function ManagedPill({ design, name }: { design: ManagedBannerDesign; name: string }) {
  const mini = design === "pill-mini";
  const lead =
    design === "pill-dot" || design === "pill-straddle" ? (
      <span className="acpmux-managed-pill-dot" aria-hidden />
    ) : design === "pill-avatar" || design === "pill-left" || design === "pill-accent" || mini ? (
      <span className="acpmux-managed-pill-avatar" aria-hidden>
        {name.slice(0, 1)}
      </span>
    ) : null;
  return (
    <div className="acpmux-managed-pill-stage" data-design={design}>
      <output className="acpmux-managed-pill" data-design={design}>
        {lead}
        {mini ? (
          <span className="acpmux-managed-pill-text">
            <strong className="acpmux-managed-name">{name}</strong> is sending
          </span>
        ) : (
          <span className="acpmux-managed-pill-text">
            <strong className="acpmux-managed-name">{name}</strong> is sending messages here
            {design === "pill" || design === "pill-glass" ? (
              <span className="acpmux-managed-pill-sub"> · you can still type</span>
            ) : null}
          </span>
        )}
        <button type="button" className="acpmux-managed-pill-hide" aria-label="Hide" title="Hide">
          {mini || design === "pill-dot" || design === "pill-straddle" || design === "pill-avatar" ? "\u00d7" : "Hide"}
        </button>
      </output>
      <div className="acpmux-managed-pill-composer">Type / for commands</div>
    </div>
  );
}


export type ManagedBannerDesignsProps = {
  design: ManagedBannerDesign;
  manager: ManagedBy;
  /** The chat's rows, when the variant shows the rule rather than a design: no line unless the
   *  manager drives the chat at `now`. */
  rows?: readonly PromptRow[];
  now?: number;
};

const noop = () => undefined;

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
