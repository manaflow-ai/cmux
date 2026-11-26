// l10n-allow-file: gallery fixtures (branch names), not shipped UI.
// The Environment card and the changes pill (`agentPane.display.environmentCard` and
// `agentPane.display.changesPill`, off by default), as a look such as the Codex one shows them: the
// card at the chat's top right beside the column, and the pill centered over the composer.
import { componentEntry } from "../../../gallery/format";
import type { PullRequestAction } from "../../../diff-viewer/PullRequestAction";
import { ChangesPill, EnvironmentCard } from "./EnvironmentCard";
import type { ChangeCounts } from "./changeCounts";
import type { CardBranch } from "./environmentCardModel";

type Props = {
  branch?: CardBranch;
  changes?: ChangeCounts;
  pullRequest?: Partial<PullRequestAction>;
  pill?: boolean;
};

const action = (over: Partial<PullRequestAction> = {}): PullRequestAction => ({
  available: true,
  busy: false,
  run: () => undefined,
  ...over,
});

function EnvironmentCardGallery({ branch, changes, pullRequest, pill = false }: Props) {
  return (
    <div
      style={
        {
          position: "relative",
          height: 300,
          background: "var(--agent-page-bg)",
          "--acpmux-header-height": "0px",
          display: "flex",
          flexDirection: "column",
          justifyContent: "flex-end",
        } as React.CSSProperties
      }
    >
      <EnvironmentCard
        branch={branch}
        changes={changes}
        onOpenChanges={() => undefined}
        onCommitOrPush={() => undefined}
        pullRequest={pullRequest ? action(pullRequest) : action()}
      />
      {pill && <ChangesPill changes={changes} onOpen={() => undefined} />}
    </div>
  );
}

const onBranch: CardBranch = { branch: "change-background-color", worktree: false, detached: false };

export default componentEntry<Props>({
  id: "agent-pane.environment-card",
  title: "Environment card and changes pill",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/session-info/EnvironmentCard.tsx#EnvironmentCard",
    "agent-session/acpmux/session-info/EnvironmentCard.tsx#ChangesPill",
  ],
  load: async () => EnvironmentCardGallery,
  styles: () => Promise.all([import("../styles.css"), import("../changes/git.css"), import("./environmentCard.css")]),
  widths: { narrow: 320, normal: 480, wide: 640 },
  variants: {
    changes: {
      note: "A branch with uncommitted work: Changes +2 -2, the branch, Commit or push, Create pull request.",
      props: { branch: onBranch, changes: { additions: 2, deletions: 2, files: 1 } },
    },
    worktree: {
      note: "A chat in a linked worktree: Worktree with its branch after it.",
      props: {
        branch: { branch: "codex/enable-worktrees", worktree: true, detached: false },
        changes: { additions: 48, deletions: 7, files: 3 },
      },
    },
    clean: {
      note: "Nothing changed yet: Changes has no counts and opens nothing.",
      props: { branch: onBranch },
    },
    "pull-request-busy": {
      note: "Create pull request running: the row waits and the status says so.",
      props: { branch: onBranch, changes: { additions: 2, deletions: 2, files: 1 }, pullRequest: { busy: true } },
    },
    "pull-request-failed": {
      note: "Create pull request refused: the host's reason under the rows.",
      props: {
        branch: onBranch,
        changes: { additions: 2, deletions: 2, files: 1 },
        pullRequest: { error: "GitHub CLI is not signed in." },
      },
    },
    "pill-one": {
      note: "The card with the pill over the composer: 1 file changed +2 -2.",
      props: { branch: onBranch, changes: { additions: 2, deletions: 2, files: 1 }, pill: true },
    },
    "pill-many": {
      note: "The pill for several files.",
      props: { branch: onBranch, changes: { additions: 312, deletions: 40, files: 12 }, pill: true },
    },
  },
});
