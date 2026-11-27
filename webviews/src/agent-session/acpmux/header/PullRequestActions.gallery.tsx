// l10n-allow-file: gallery fixture data, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import { PullRequestActions } from "./PullRequestActions";
import type { PullRequestOps } from "./pullRequestOps";
import "./header.css";

function Actions({ state = "ready" }: { state?: "ready" | "reading" | "error" }) {
  const busy = state === "reading";
  const ops: PullRequestOps = {
    identity: "gallery",
    merging: { step: "idle" },
    messages: [],
    headSha: "a".repeat(40),
    actions: [
      { id: "state", label: "Refresh", enabled: !busy, run() {} },
      { id: "fixChecks", label: busy ? "Reading check logs…" : "Fix checks", enabled: !busy, run() {} },
      { id: "addressComments", label: "Address comments", enabled: !busy, run() {} },
      { id: "arm", label: "Merge when ready", enabled: !busy, run() {} },
    ],
    actionMessages: state === "error" ? ["The pull request changed; read its new head before acting"] : [],
  };
  return (
    <div className="acpmux-pr-status">
      <PullRequestActions ops={ops} />
    </div>
  );
}
export default componentEntry({
  id: "agent-pane.pr-actions",
  title: "PR action states",
  area: "Agent pane",
  pane: true,
  height: 320,
  widths: { narrow: 320, normal: 420 },
  covers: ["agent-session/acpmux/header/PullRequestActions.tsx"],
  load: async () => Actions,
  variants: {
    ready: { note: "Full displayed head and explicit person actions.", props: { state: "ready" } },
    reading: { note: "Busy labels retain action widths while fetching context.", props: { state: "reading" } },
    error: { note: "A changed head is reported without sending a stale prompt.", props: { state: "error" } },
  },
});
