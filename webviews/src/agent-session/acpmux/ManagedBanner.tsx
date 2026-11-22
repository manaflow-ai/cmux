import { useT } from "./i18n";
import type { ManagedBy } from "./managedBy";
import "./managedBanner.css";

/// The line over the composer of a chat the Chief or another chat's agent is driving now
/// (managedBy.ts `managerDrivingUntil`): "<name> is sending messages here. What you type still
/// sends as you.", the name bold, and Hide. It says what it means for the person: another agent is
/// prompting this chat, and their own prompt is still theirs (Leo, 2026-11-03: "what does 'managing
/// this chat' even mean?"). Its name opens the managing chat when it is one here. Hide hides the
/// line for this chat on this Mac and focuses the composer; it holds none of the manager's messages.
export function ManagedBanner({
  manager,
  onHide,
  onOpenManager,
}: {
  manager: ManagedBy;
  onHide(): void;
  onOpenManager?(sessionId: string): void;
}) {
  const t = useT();
  // l10n-allow: Chief is the product's name for it, never translated.
  const name = manager.kind === "chief" ? "Chief" : manager.name;
  const [before, after = ""] = t("managed.sending", { name: "\u0000" }).split("\u0000");
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
      <button type="button" className="acpmux-managed-take-over" onClick={onHide}>
        {t("managed.hide")}
      </button>
    </output>
  );
}
