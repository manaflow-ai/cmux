// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { PullRequestActionButton, PullRequestActionStatus, type PullRequestAction } from "./PullRequestAction";

type Props = { state: "ready" | "busy" | "error" };

function Gallery({ state }: Props) {
  const action: PullRequestAction = {
    available: true,
    busy: state === "busy",
    error: state === "error" ? "Push rejected: the remote branch has newer commits. Pull, then try again." : undefined,
    run: () => undefined,
  };
  return (
    <div
      className="diff-git diff-git-tools"
      style={{ display: "flex", flexDirection: "column", gap: "var(--ds-space-2)", padding: "var(--ds-space-3)" }}
    >
      <div>
        <PullRequestActionButton action={action} />
      </div>
      <PullRequestActionStatus action={action} />
    </div>
  );
}

const click: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Create PR" });
};

export default componentEntry<Props>({
  id: "diff-viewer.pull-request-action",
  title: "Diff Create PR",
  area: "Diff viewer",
  covers: ["diff-viewer/PullRequestAction.tsx#PullRequestActionButton"],
  load: async () => Gallery,
  styles: () =>
    Promise.all([import("../agent-session/acpmux/styles.css"), import("../agent-session/acpmux/changes/changes.css")]),
  widths: { narrow: 320, normal: 480, wide: 640 },
  variants: {
    ready: { note: "Create PR is available on the current branch.", props: { state: "ready" } },
    busy: {
      note: "The branch is being pushed and its pull request is opening.",
      props: { state: "busy" },
    },
    error: {
      note: "The remote rejected the push with an actionable error.",
      props: { state: "error" },
      play: click,
    },
  },
});
