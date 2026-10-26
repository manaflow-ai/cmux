import { useMemo } from "react";
import { EditDiff } from "../conversation/EditDiff";
import { toolFiles } from "../diff";
import type { AcpmuxFileDiff } from "../model";

/** Both approval surfaces show the request's edits whole, before the person answers. */
export function ProposedEdits({ permissionId, diffs }: { permissionId: string; diffs?: AcpmuxFileDiff[] }) {
  const files = useMemo(
    () => (diffs ? toolFiles([{ id: permissionId, title: "", status: "proposed", diffs }]) : []),
    [permissionId, diffs],
  );
  return files.map((file) => <EditDiff key={file.path} file={file} whole />);
}
