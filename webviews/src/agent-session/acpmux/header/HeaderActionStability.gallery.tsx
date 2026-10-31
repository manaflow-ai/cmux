// l10n-allow-file: gallery fixture data, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { PullRequestMerge, type Merging } from "./PullRequestMerge";
import { WorktreeApply, type Applying } from "./WorktreeApply";
import { WorktreeRemove, type Removing } from "./WorktreeRemove";
import "./header.css";

const worktree = { branch: "fix-login", base: "main", mainRoot: "/Users/me/Projects/cmux" };
const pullRequest = {
  number: 19605,
  url: "https://github.com/manaflow-ai/cmux/pull/19605",
  title: "Fix login",
  state: "open",
  review: "approved",
  mergeable: "mergeable",
  checks: { state: "passing", passed: 3, total: 3 },
  checkList: [],
};

function HeaderActionStability({ busy = false }: { busy?: boolean }) {
  const [merging, setMerging] = useState<Merging>({ step: busy ? "merging" : "confirm" });
  const [applying, setApplying] = useState<Applying>(busy ? { step: "applying", key: "gallery" } : { step: "idle" });
  const [removing, setRemoving] = useState<Removing>(
    busy ? { step: "removing", key: "gallery", discard: false } : { step: "idle" },
  );
  return (
    <div style={{ width: 280, padding: 8 }}>
      <PullRequestMerge
        pullRequest={pullRequest}
        merging={merging}
        setMerging={setMerging}
        merge={() => new Promise(() => undefined)}
      />
      <WorktreeApply
        worktree={worktree}
        applying={applying}
        setApplying={setApplying}
        apply={() => new Promise(() => undefined)}
      />
      <WorktreeRemove
        worktree={worktree}
        removing={removing}
        setRemoving={setRemoving}
        remove={() => new Promise(() => undefined)}
      />
    </div>
  );
}

export default componentEntry({
  id: "agent-pane.header-action-stability",
  title: "PR and worktree stable actions",
  area: "Agent pane",
  pane: true,
  height: 240,
  widths: { narrow: 320, normal: 420 },
  covers: [
    "ui/StableLabel.tsx",
    "agent-session/acpmux/header/PullRequestMerge.tsx",
    "agent-session/acpmux/header/WorktreeApply.tsx",
    "agent-session/acpmux/header/WorktreeRemove.tsx",
  ],
  load: async () => HeaderActionStability,
  variants: {
    idle: {
      note: "Confirm merge, Apply and Remove reserve their busy-state label widths.",
      props: {},
    },
    busy: {
      note: "Merging, Applying and Removing keep the same widths as their idle controls.",
      props: { busy: true },
    },
  },
});
