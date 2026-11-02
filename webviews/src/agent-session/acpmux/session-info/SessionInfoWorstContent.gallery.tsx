// l10n-allow-file: synthetic worst-case gallery data, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { SummaryPullRequest } from "../summary/sessionSummary";
import { ChangesSection, type SessionInfoPullRequestStatus } from "./ChangesSection";
import "./sessionInfo.css";

const names = [
  "Aleksandra Wiśniewska-Kowalczyk-".repeat(4),
  "王秀英".repeat(20),
  "عبد الرحمن".repeat(10),
  "🦊 Fox",
  "",
];
const counts = [0, 1, 1_284, Number.MAX_SAFE_INTEGER];
const repository = `example/${"long-unbreakable-repository".replaceAll("-", "").repeat(5)}`;
const pullRequests: SummaryPullRequest[] = names.map((title, index) => ({
  url: `https://github.com/${repository}/pull/${index + 1}`,
  repo: repository,
  number: index + 1,
  title,
  opened: true,
  state: "open",
}));

type Props = { count: number; failing?: boolean; breakdown?: boolean };
function WorstChanges({ count, failing = false, breakdown = false }: Props) {
  const statuses: Record<string, SessionInfoPullRequestStatus> = Object.fromEntries(
    pullRequests.map((pr, index) => [
      pr.url,
      {
        owner: names[index],
        additions: count,
        deletions: count,
        comments: count,
        checks: failing ? "failing" : "passing",
        failing: failing ? count : 0,
        breakdown: breakdown ? { code: { additions: count, deletions: count } } : undefined,
      },
    ]),
  );
  return (
    <div className="acpmux-shell">
      <ChangesSection pullRequests={pullRequests} statuses={statuses} onOpenBeside={() => undefined} />
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.inspector-worst-content",
  title: "Session Info · worst content",
  area: "Agent pane",
  pane: true,
  height: 300,
  widths: { narrow: 280, normal: 320, wide: 560 },
  covers: ["agent-session/acpmux/session-info/ChangesSection.tsx"],
  load: async () => WorstChanges,
  variants: {
    ...Object.fromEntries(
      counts.map((count) => [
        `count-${count}`,
        {
          note: "Long repository, hyphenated, CJK, RTL, emoji-first and missing titles; counts stay inside the row.",
          props: { count },
        },
      ]),
    ),
    "counts-with-breakdown": {
      note: "The same metadata with the production line-breakdown tooltip wrapper.",
      props: { count: Number.MAX_SAFE_INTEGER, breakdown: true },
    },
    "failing-checks": {
      note: "Long repository and maximum counts with failing checks instead of the passing mark.",
      props: { count: Number.MAX_SAFE_INTEGER, failing: true },
    },
  },
});
