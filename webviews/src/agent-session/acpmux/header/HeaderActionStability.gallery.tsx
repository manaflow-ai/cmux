// l10n-allow-file: gallery fixture data, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import { PullRequestMerge, type Merging } from "./PullRequestMerge";
import type { PullRequestOps } from "./pullRequestOps";
import { WorktreeApply } from "./WorktreeApply";
import { WorktreeRemove } from "./WorktreeRemove";
import type { Applying, Removing, WorktreeOps } from "./worktreeOps";
import "./header.css";

function HeaderActionStability({ busy = false }: { busy?: boolean }) {
  const merging: Merging = { step: busy ? "merging" : "confirm" };
  const applying: Applying = busy ? { step: "applying", key: "gallery" } : { step: "idle" };
  const removing: Removing = busy ? { step: "removing", key: "gallery", discard: false } : { step: "idle" };
  const prOps: PullRequestOps = {
    identity: "gallery-pr",
    merging,
    confirm: { label: busy ? "Merging" : "Confirm merge", enabled: !busy, run: () => undefined },
    cancel: { label: "Cancel", enabled: !busy, run: () => undefined },
    messages: [],
    question: "Merge this pull request?",
  };
  const worktreeOps: WorktreeOps = {
    identity: "gallery-worktree",
    applying,
    removing,
    apply: { label: busy ? "Applying" : "Apply", enabled: !busy, run: () => undefined },
    remove: { label: busy ? "Removing" : "Remove", enabled: !busy, run: () => undefined },
    messages: [],
    canRemove: true,
  };
  return (
    <div style={{ width: 280, padding: 8 }}>
      <PullRequestMerge ops={prOps} />
      <WorktreeApply ops={worktreeOps} />
      <WorktreeRemove ops={worktreeOps} />
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
