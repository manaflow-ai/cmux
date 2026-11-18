// l10n-allow-file: synthetic gallery draft and pull request, not shipped UI.
// The composer after Changes' Fix Failing Checks (Labs, session-info/prFeedback.ts): acpmux's message
// is in the composer after what was typed, unsent. The mock transport does not answer
// `_acpmux/pr_feedback`, so the play puts a sample answer's draft in the way App.tsx does
// (`chat.quoteReply`, composerRestore.ts `quoteIntoComposer`).
import { agentPaneEntry } from "../../../gallery/format";
import { chat } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";

const typed = "Also keep the retry cap.";
const draft = [
  "Fix the failing checks of example/project#42 that are this branch's own (1 more also fails on base, so leave it):",
  "",
  "- **lint** (step: Run vp lint)",
  "  ```",
  "  src/retry.ts:12:3 error no-unused-vars",
  "  ```",
  "- **unit-tests**",
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
