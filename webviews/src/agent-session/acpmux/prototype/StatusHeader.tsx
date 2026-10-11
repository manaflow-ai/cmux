// A status group's header in the grouped workspace list (#16688): its name and how many
// workspaces it holds.
import type { StatusGroup } from "./rowDetail";

export function StatusHeader({ group }: { group: StatusGroup<unknown> }) {
  return (
    <div className="proto-status-header" data-status={group.status}>
      <span>{group.label}</span>
      <span className="proto-status-count">{group.items.length}</span>
    </div>
  );
}
