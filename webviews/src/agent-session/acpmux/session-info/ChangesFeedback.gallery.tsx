// l10n-allow-file: synthetic gallery pull requests, not shipped UI.
// Changes' Fix Failing Checks and Send Review Comments (Labs, prFeedback.ts) in a pull request's ⋯
// menu: both on a pull request with reds of its own, only Send Review Comments where every red also
// fails on base, and neither with preview features off.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { ChangesSection } from "./ChangesSection";
import type { SessionInfoPullRequestStatus } from "./changesSectionModel";
import { SessionInfoPanel } from "./SessionInfo";

const url = "https://github.com/example/project/pull/42";

const STATUSES: Record<string, SessionInfoPullRequestStatus> = {
  own: {
    title: "Retry webhook deliveries with backoff",
    state: "open",
    checks: "failing",
    failing: 3,
    failingOnBase: 1,
  },
  base: {
    title: "Retry webhook deliveries with backoff",
    state: "open",
    checks: "failing",
    failing: 2,
    failingOnBase: 2,
  },
};

function ChangesFeedback({ status, preview }: { status: "own" | "base"; preview: boolean }) {
  return (
    <section className="acpmux-shell" style={{ height: "100%", minHeight: 240 }}>
      <SessionInfoPanel width={360} placement="overlay">
        <div className="acpmux-session-info__body">
          <ChangesSection
            statuses={{ [url]: STATUSES[status]! }}
            pullRequests={[{ url, repo: "example/project", number: 42, opened: true, state: "open" }]}
            onDraftFeedback={preview ? () => undefined : undefined}
          />
        </div>
      </SessionInfoPanel>
    </section>
  );
}

const openMenu: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-session-info-pr__more" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]'));
};

export default componentEntry<{ status: "own" | "base"; preview: boolean }>({
  id: "agent-pane.session-info-changes-feedback",
  title: "Changes: Fix Failing Checks and Send Review Comments",
  area: "Agent pane",
  pane: true,
  height: 420,
  widths: { narrow: 640, normal: 900 },
  covers: [
    "agent-session/acpmux/session-info/ChangesSection.tsx#PullRequestRow",
    "agent-session/acpmux/session-info/prFeedback.ts",
  ],
  load: async () => ChangesFeedback,
  variants: {
    "own-and-base-reds": {
      note: "3 failing, 1 of them on base too: both items show.",
      props: { status: "own", preview: true },
      play: openMenu,
    },
    "base-reds-only": {
      note: "Every red also fails on base: no Fix Failing Checks, Send Review Comments still shows.",
      props: { status: "base", preview: true },
      play: openMenu,
    },
    "preview-off": {
      note: "Preview features off (the default): neither item.",
      props: { status: "own", preview: false },
      play: openMenu,
    },
  },
});
