import { useMemo } from "react";
import { EditDiff } from "../conversation/EditDiff";
import { toolFiles } from "../diff";
import type { AcpmuxFileDiff } from "../model";

/** Both approval surfaces show the request's edits whole, before the person answers. A long diff
 *  scrolls inside its own frame (styles.css `.acpmux-permission-edits`), so it never pushes the
 *  answer buttons or the rest of the ask out of view. */
export function ProposedEdits({ permissionId, diffs }: { permissionId: string; diffs?: AcpmuxFileDiff[] }) {
  const files = useMemo(
    () => (diffs ? toolFiles([{ id: permissionId, title: "", status: "proposed", diffs }]) : []),
    [permissionId, diffs],
  );
  if (!files.length) return null;
  return (
    <div className="acpmux-permission-edits">
      {files.map((file) => (
        <EditDiff key={file.path} file={file} whole />
      ))}
    </div>
  );
}
