// l10n-allow-file: synthetic gallery draft and pull request, not shipped UI.
// The composer after Changes' Fix Failing Checks (Labs, session-info/prFeedback.ts): acpmux's message
// is in the composer after what was typed, unsent. The mock transport does not answer
// `_acpmux/pr_feedback`, so the play puts a sample answer's draft in the way App.tsx does
// (`chat.quoteReply`, composerRestore.ts `quoteIntoComposer`).
import { agentPaneEntry } from "../../../gallery/format";
import { chat } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";

const typed = "Also keep the retry cap.";
// As acpmux words it (cmux-tui/crates/acpmux/src/pr_feedback/draft.rs `checks`).
const draft = [
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
  "",
].join("\n");

const insert: Play = async (ctx) => {
  const page = ctx.document.defaultView as unknown as {
    cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => unknown>;
  };
  await ctx.waitFor(() => !!page.cmuxAcpmuxActions?.["chat.quoteReply"]);
  page.cmuxAcpmuxActions!["chat.quoteReply"]({ markdown: draft });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-md-field")?.textContent?.includes("unit-tests"));
};

export default agentPaneEntry({
  id: "agent-pane.session-info-changes-feedback-draft",
  title: "Changes: a checks message in the composer, unsent",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 400, normal: 760 },
  covers: ["agent-session/acpmux/session-info/prFeedback.ts", "agent-session/acpmux/Composer.tsx"],
  variants: {
    "checks-draft": {
      note: "Fix Failing Checks put its message after the typed text; nothing was sent.",
      ready: { transport: "mock", draft: typed },
      snapshot: chat([]),
      play: insert,
    },
  },
});
