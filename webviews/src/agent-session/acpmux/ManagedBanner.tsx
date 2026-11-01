import { useT } from "./i18n";
import type { ManagedBy } from "./managedBy";
import "./managedBanner.css";

/// The line over the composer of a chat the Chief or another chat's agent runs (managedBy.ts):
/// "<name> is managing this chat", the name bold, and Take over, as ChatGPT shows a chat its agent
/// runs (Leo, 2026-11-01). Its name opens the managing chat when it is one here. Take over hides the
/// line for this chat; the person's own prompt is already theirs to send.
export function ManagedBanner({
  manager,
  onTakeOver,
  onOpenManager,
}: {
  manager: ManagedBy;
  onTakeOver(): void;
  onOpenManager?(sessionId: string): void;
}) {
  const t = useT();
  // l10n-allow: Chief is the product's name for it, never translated.
  const name = manager.kind === "chief" ? "Chief" : manager.name;
  const [before, after = ""] = t("managed.banner", { name: "\u0000" }).split("\u0000");
  const opens = manager.kind === "agent" && onOpenManager ? manager.sessionId : undefined;
  return (
    <output className="acpmux-managed-banner" data-managed={manager.kind}>
      <span className="acpmux-managed-text">
        {before}
        {opens ? (
          <button type="button" className="acpmux-managed-name" onClick={() => onOpenManager?.(opens)}>
            {name}
          </button>
        ) : (
          <strong className="acpmux-managed-name">{name}</strong>
        )}
        {after}
      </span>
      <button type="button" className="acpmux-managed-take-over" onClick={onTakeOver}>
        {t("managed.takeOver")}
      </button>
    </output>
  );
}
