import type { FolderAsk } from "./startFolder";
import { StartFolderAsk } from "./startFolder";

/// A folder confirmation that stays visible while the New Tab surface remains mounted.
/// The regular composer is hidden behind that surface, so the ask needs its own mounted host.
export function NewTabFolderAsk({
  ask,
  current,
  error,
  confirming,
  onUse,
  onCancel,
}: {
  ask: FolderAsk;
  current?: string;
  error?: string;
  confirming?: boolean;
  onUse(): void;
  onCancel(): void;
}) {
  return (
    <div className="acpmux-newtab-folder-ask">
      <StartFolderAsk
        ask={ask}
        current={current}
        error={error}
        confirming={confirming}
        onUse={onUse}
        onCancel={onCancel}
      />
    </div>
  );
}
