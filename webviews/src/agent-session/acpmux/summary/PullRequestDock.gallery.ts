// l10n-allow-file: gallery fixtures (sample prompts, commands and pull request titles), not shipped UI.
// Compact PR links in the message row, with one-link and tighter alternatives.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";

const create = (title: string, number: number) =>
  tool(`gh pr create --title "${title}"`, "execute", "completed", {
    command: `gh pr create --title "${title}" --fill`,
    output: `https://github.com/acme/atlas-web/pull/${number}\n`,
    exitCode: 0,
  });
const four = [
  create("Add retry", 128),
  create("Cover retry", 129),
  create("Document retry", 130),
  create("Log retry", 131),
];
const snapshot = chat([
  user("Split the change into four PRs", 6),
  activity(four, 5),
  assistant("Four PRs are open.", 2),
  summary(2, { status: "completed", durationMs: 68_000, toolCount: 4 }),
]);
export default agentPaneEntry({
  id: "agent-pane.pr-dock",
  title: "Inline pull request pills",
  area: "Agent pane",
  height: 420,
  covers: ["agent-session/acpmux/summary/PullRequestDock.tsx"],
  variants: {
    "compact-count": {
      note: "Selected: up to two underlined PR links beside the action row, plus instant overflow.",
      snapshot,
    },
    "one-first": {
      note: "Alternative: one link and the remainder behind +N, saving more width.",
      documentAttributes: { "pr-dock": "one" },
      snapshot,
    },
    tight: {
      note: "Alternative: the same links with tighter horizontal spacing.",
      documentAttributes: { "pr-dock": "tight" },
      snapshot,
    },
    "no-footer": {
      note: "While the answer streams, links sit right of its last line without an action row.",
      snapshot: chat([
        activity(four, 5),
        assistant(
          "The uploader retries transient failures while preserving the existing response and its error details. This earlier paragraph keeps the full message width.\n\n```ts\nconst response = await uploadWithRetry(payload, { attempts: 3, delay: 250 });\n```\n\nFour PRs are ready for review.",
          2,
          { streaming: true },
        ),
      ]),
    },
    "code-tail": {
      note: "Footerless final code keeps PR links visible.",
      snapshot: chat([
        activity(four, 5),
        assistant("```ts\nconst response = await uploadWithRetry(payload);\n```", 2, { streaming: true }),
      ]),
    },
    "table-tail": {
      note: "Footerless final table keeps PR links visible.",
      snapshot: chat([
        activity(four, 5),
        assistant("| Result | State |\n| --- | --- |\n| Build | Passed |", 2, { streaming: true }),
      ]),
    },
    "math-tail": {
      note: "Footerless final math keeps PR links visible.",
      snapshot: chat([activity(four, 5), assistant("$$x^2 + y^2 = z^2$$", 2, { streaming: true })]),
    },
    "rule-tail": {
      note: "Footerless final rule keeps PR links visible.",
      snapshot: chat([activity(four, 5), assistant("The checks passed.\n\n---", 2, { streaming: true })]),
    },
    "diagram-tail": {
      note: "Footerless final diagram keeps PR links visible.",
      snapshot: chat([activity(four, 5), assistant("```mermaid\nflowchart LR\nA --> B\n```", 2, { streaming: true })]),
    },
    "notes-tail": {
      note: "Links share the final visible note even when definitions arrive in a different order.",
      snapshot: chat([
        activity(four, 5),
        assistant("The checks passed[^first][^second].\n\n[^second]: Second note.\n\n[^first]: First note.", 2, {
          streaming: true,
        }),
      ]),
    },
    one: {
      note: "One PR is a single link with no disclosure or remove button.",
      snapshot: chat([
        activity([create("Add retry", 128)], 3),
        assistant("Ready for review.", 2),
        summary(2, { status: "completed", toolCount: 1 }),
      ]),
    },
    received: {
      note: "A received message keeps PR links beside its existing actions.",
      snapshot: chat([
        activity(four, 3),
        user("Ready for review.", 1, {
          incoming: {
            kind: "message",
            message: { name: "review", text: "Ready for review.", raw: "Ready for review." },
          },
          untyped: true,
        }),
      ]),
    },
  },
});
