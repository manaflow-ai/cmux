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

export type ManagedBannerDesign = "sending" | "driving" | "placeholder";

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
        style={{ padding: "12px 16px", color: "var(--acpmux-composer-placeholder)" }}
      >
        {name} is sending messages here. Type to reply as you
      </div>
    </div>
  );
}
