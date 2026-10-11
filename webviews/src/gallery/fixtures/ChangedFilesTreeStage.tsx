// l10n-allow-file: gallery fixtures, not shipped UI.
// The changes tree as the changes view hosts it (DiffPanel's tree column: a column of the pane's
// border and background, the real ChangedFilesTree inside), for the gallery's component host.
// The column's class is not used: its `max-width: 620px` rule hides the tree in a frame as narrow
// as the column itself.
import { useState } from "react";
import type { TurnFile } from "../../agent-session/acpmux/diff";
import { ChangedFilesTree } from "../../agent-session/acpmux/changes/ChangedFilesTree";

export function ChangedFilesTreeStage({ files }: { files: TurnFile[] }) {
  const [selected, setSelected] = useState<string | undefined>();
  return (
    <nav
      aria-label="Changed files"
      style={{
        display: "flex",
        flexDirection: "column",
        height: "100vh",
        boxSizing: "border-box",
        borderLeft: "1px solid var(--agent-border)",
        background: "var(--agent-page-bg)",
        overflow: "hidden",
      }}
    >
      <ChangedFilesTree files={files} selected={selected} onSelect={setSelected} />
    </nav>
  );
}
