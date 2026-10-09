import { Icon } from "../icons/Icon";

/// The header's connection problem, when there is one. The slot stays in place; the problem label cannot
/// resize it or move the header tools. The tone tells a retry (warning) from a lost or failed connection
/// (error) at a glance, on the icon only, so the text stays calm. When the detail says more than the label,
/// the accessible label carries both, so a screen reader announces the reason, not only "Failed".
export function ChatHeaderStatus({
  status,
  detail,
  tone,
}: {
  status: string;
  detail?: string;
  tone?: "warning" | "error";
}) {
  const more = detail && detail !== status ? detail : undefined;
  return (
    <div className="acpmux-header-status-slot">
      {status && (
        <output
          className={`acpmux-status ${
            tone === "error" ? "[&>svg]:text-danger" : tone === "warning" ? "[&>svg]:text-warning" : ""
          }`}
          data-tone={tone}
          title={more}
          aria-label={more ? `${status}: ${more}` : status}
        >
          <Icon name="status.warning" size={13} />
          <span>{status}</span>
        </output>
      )}
    </div>
  );
}
