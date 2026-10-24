// l10n-allow-file: gallery fixtures (sample prompts, commands and pull request titles), not shipped UI.
// The chat's pull requests above the composer (PullRequestDock.tsx, cx-ncc.81): each `gh pr create`
// in the chat shows as a bar with its state until it is merged or closed; past two, the rest wait
// behind Show more.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";

const create = (title: string, number: number) =>
  tool(`gh pr create --title "${title}"`, "execute", "completed", {
    command: `gh pr create --title "${title}" --fill`,
    output: `https://github.com/acme/atlas-web/pull/${number}\n`,
    exitCode: 0,
  });
const merge = (number: number) =>
  tool(`gh pr merge ${number} --squash`, "execute", "completed", {
    command: `gh pr merge ${number} --squash`,
    output: "Merged",
    exitCode: 0,
  });

export default agentPaneEntry({
  id: "agent-pane.pr-dock",
  title: "Pull request bars",
  area: "Agent pane",
  height: 420,
  covers: ["agent-session/acpmux/summary/PullRequestDock.tsx"],
  variants: {
    one: {
      note: "One pull request the chat opened, open.",
      snapshot: chat([
        user("Open a PR for the retry change", 4),
        activity([create("Add retry to the uploader", 128)], 3),
        assistant("Opened #128.", 2),
        summary(2, { status: "completed", durationMs: 21_000, toolCount: 1 }),
      ]),
    },
    "just-merged": {
      note: "The newest pull request merged in this turn: it leaves the dock; the open one stays.",
      snapshot: chat([
        user("Open the docs PR and merge it", 4),
        activity([create("Add retry to the uploader", 128), create("Document retry", 129), merge(129)], 3),
        assistant("#129 is merged; #128 stays open.", 2),
        summary(2, { status: "completed", durationMs: 33_000, toolCount: 3 }),
      ]),
    },
    several: {
      note: "Four pull requests, the first merged: it keeps no bar; the newest two show, one more behind Show more.",
      snapshot: chat([
        user("Split the change into four PRs and merge the first", 6),
        activity(
          [
            create("Add retry to the uploader", 128),
            create("Cover retry with a test", 129),
            create("Document retry in the README", 130),
            create("Log each retry", 131),
            merge(128),
          ],
          5,
        ),
        assistant("Three PRs open; #128 is merged.", 2),
        summary(2, { status: "completed", durationMs: 74_000, toolCount: 5 }),
      ]),
    },
    "long-title": {
      note: "A long title uses the composer's width and is cut off only at the column's edge.",
      snapshot: chat([
        user("Open a PR for the rulebook change", 4),
        activity(
          [
            create(
              "rulebook: reviewed PRs merge right away; the label is the fallback when the owner cannot merge, and base reds never block a merge",
              634,
            ),
          ],
          3,
        ),
        assistant("Opened #634.", 2),
        summary(2, { status: "completed", durationMs: 21_000, toolCount: 1 }),
      ]),
    },
  },
});
