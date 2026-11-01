// l10n-allow-file: gallery-only recovery fixtures.
import { componentEntry } from "../../../gallery/format";
import { RepoRecoveryCard, type RepoRecovery } from "./RepoRecoveryCard";

type Props = { recovery: RepoRecovery };

const needsGithub: RepoRecovery = {
  code: "repo.needs_github",
  installUrl: "https://github.com/apps/cmux/installations/new",
  retry: { action: "cloud.repo.add", args: { session: "cloud-demo", repo: "acme/cmux-platform" }, wait_action: "cloud.repo.wait_github" },
};
const noAccess: RepoRecovery = {
  code: "repo.no_access",
  org: "acme",
  installUrl: "https://github.com/apps/cmux/installations/new",
};
const ambiguous: RepoRecovery = {
  code: "repo.ambiguous",
  choices: [
    { fullName: "acme/cmux-platform", private: true, source: "recent" },
    { fullName: "manaflow-ai/cmux-platform", source: "installation" },
  ],
  retry: { action: "cloud.repo.add", args: { session: "cloud-demo", repo: "cmux-platform" } },
};

export default componentEntry<Props>({
  id: "agent-pane.repo-recovery",
  title: "Cloud repository recovery",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 360, normal: 560, wide: 720 },
  covers: ["agent-session/acpmux/conversation/RepoRecoveryCard.tsx#RepoRecoveryCard"],
  styles: () => import("./conversation.css"),
  load: async () => function RepoRecoveryGallery({ recovery }: Props) {
    return <div style={{ padding: "24px" }}><RepoRecoveryCard recovery={recovery} /></div>;
  },
  variants: {
    "needs-github": { note: "A quiet Connecting GitHub step keeps the failed tool recoverable.", props: { recovery: needsGithub } },
    "no-access": { note: "The organization is named with install and request actions.", props: { recovery: noAccess } },
    ambiguous: { note: "Several matching repositories are one tap away.", props: { recovery: ambiguous } },
  },
});
