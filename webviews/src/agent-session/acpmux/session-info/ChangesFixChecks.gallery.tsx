// l10n-allow-file: synthetic gallery pull request and checks, not shipped UI.
// Changes' Fix failing checks button (experiment `changes-fix-checks-button`, off by default;
// FixChecksButton.tsx) on a pull request with 3 failing checks, 1 of them failing on base too: the
// button counts 2, and each arm says what it sends. "now" is today's row (Labs' ⋯ menu item only).
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { ChangesSection } from "./ChangesSection";
import type { SessionInfoPullRequestStatus } from "./changesSectionModel";
import { SessionInfoPanel } from "./SessionInfo";
import { fixChecksButton, type FixChecksLook } from "./fixChecks.experiment";
import type { FixChecksActions } from "./FixChecksButton";

const url = "https://github.com/example/project/pull/42";

const STATUS: SessionInfoPullRequestStatus = {
  title: "Retry webhook deliveries with backoff",
  state: "open",
  checks: "failing",
  failing: 3,
  failingOnBase: 1,
  additions: 182,
  deletions: 41,
};

// As acpmux answers it (cmux-tui/crates/acpmux/src/pr_feedback.rs `answer`, draft.rs `checks`).
const ANSWER = {
  kind: "checks",
  empty: false,
  draft: [
    "Fix the failing checks on example/project#42 (head 4db9066b). These 2 fail on this branch only:",
    "",
    "### lint (CI)",
    "Failing step: Run vp lint",
    "https://github.com/example/project/actions/runs/1/job/2",
    "```text",
    "src/retry.ts:12:3 error no-unused-vars",
    "##[error]Process completed with exit code 1.",
    "```",
    "",
    "### unit-tests (CI)",
    "Failing step: Run bun test",
    "https://github.com/example/project/actions/runs/1/job/3",
    "",
    "Left out: 1 failing check that also fails on main's tip, so not this branch's (e2e).",
  ].join("\n"),
  checks: {
    own: [
      {
        name: "lint",
        workflow: "CI",
        step: "Run vp lint",
        url: "https://github.com/example/project/actions/runs/1/job/2",
      },
      {
        name: "unit-tests",
        workflow: "CI",
        step: "Run bun test",
        url: "https://github.com/example/project/actions/runs/1/job/3",
      },
    ],
    onBase: ["e2e"],
    pending: 0,
  },
};

const actions: FixChecksActions = {
  read: () => ({ answer: Promise.resolve(ANSWER), stillShown: () => true }),
  send: () => undefined,
};

function ChangesFixChecks({ look }: { look: FixChecksLook }) {
  // Gallery only: the row reads its arm as it mounts, after this sets it.
  globalThis.cmuxExperiments = { ...globalThis.cmuxExperiments, [fixChecksButton.id]: look };
  return (
    <section className="acpmux-shell" style={{ height: "100%", minHeight: 240 }}>
      <SessionInfoPanel width={360} placement="overlay">
        <div className="acpmux-session-info__body">
          <ChangesSection
            statuses={{ [url]: STATUS }}
            pullRequests={[{ url, repo: "example/project", number: 42, opened: true, state: "open" }]}
            onDraftFeedback={() => undefined}
            fixChecks={actions}
          />
        </div>
      </SessionInfoPanel>
    </section>
  );
}

const hoverButton: Play = async (ctx) => {
  await ctx.hover({ selector: ".acpmux-session-info-fix" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-info-fix__list li"));
};

const openPreview: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-session-info-fix" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-info-fix__draft"));
};

export default componentEntry<{ look: FixChecksLook }>({
  id: "agent-pane.session-info-changes-fix-checks",
  title: "Changes: Fix failing checks button",
  area: "Agent pane",
  pane: true,
  height: 460,
  widths: { narrow: 640, normal: 900 },
  covers: [
    "agent-session/acpmux/session-info/FixChecksButton.tsx",
    "agent-session/acpmux/session-info/fixChecks.ts",
    "agent-session/acpmux/session-info/ChangesSection.tsx#PullRequestRow",
  ],
  load: async () => ChangesFixChecks,
  variants: {
    now: {
      note: "Today (the experiment's default, off): no button; Labs' ⋯ menu has Fix Failing Checks.",
      props: { look: "off" },
    },
    quiet: {
      note: "(a) A quiet text button under the row: Fix 2 failing checks. A click drafts the message into the composer.",
      props: { look: "quiet" },
    },
    count: {
      note: "(b) A red-count button; its hover lists what it sends and the base red it leaves out.",
      props: { look: "count" },
      play: hoverButton,
    },
    preview: {
      note: "(c) A click previews the message the agent gets, names the base red not sent, and Send sends it.",
      props: { look: "preview" },
      play: openPreview,
    },
  },
});
