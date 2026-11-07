// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// A closed "Worked for" never hides a reply to the person (Leo, 2026-11-06, on a closed "Worked for
// 2m 22s" that hid his answer: "your intermediate message got lost. that can never happen", then
// "those intermediate messages should be counted differently than other tool calls like it's a
// special never-fold type"). Each variant is one finished turn with replies before, between and after
// its work; the arms of turnFoldReplies.experiment.ts differ only in how the work between the replies
// folds: one line per stretch (shipped), one line per run, or none (all of it under Worked for).
// Test: turn-fold-keeps-replies.test.ts.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { turnFoldReplies } from "./turnFoldReplies.experiment";

const run = (description: string, command: string): AcpmuxActivity =>
  tool(command, "execute", "completed", { description, command, output: "ok\n", exitCode: 0 });

/// Leo's turn: a scheduled check, a reply, four commands, his answer between two tool groups, a
/// message sent and a command, then the turn's last words.
function leosTurn(): AcpmuxRow[] {
  return [
    user("Are Cloud workspaces grouped like the others?", 30),
    activity(
      [
        run("Listed the workspace groups", "cmux workspace list --json"),
        run("Scheduled a wakeup", "cmux schedule wakeup --in 20m"),
        run("Sent the lane its brief", "lane-gh send cloud-lane -"),
      ],
      29.5,
    ),
    assistant(
      "Right. The command-line test comes first:\n\n" +
        "- **A clicking test:** the start of a Cloud chat in the current nightly, timed per step.\n" +
        "- **Cloud UI in React:** a new web view for the Cloud page, with a thin bridge left in Swift.",
      28,
    ),
    activity(
      [
        run("Read the grouping code", "rg -n 'groupFor' Sources/Workspaces"),
        run("Read the machine model", "rg -n 'machine_id' Sources/Cloud"),
        run("Ran the grouping tests", "swift test --filter Grouping"),
        run("Checked the branch", "git status --short"),
      ],
      26,
    ),
    assistant(
      "No, they aren't treated normally. Each Cloud machine gets its own group, so every Cloud workspace on one machine lands together.\n\n" +
        "- A Cloud workspace goes into its machine's group.\n" +
        "- There's no automatic group by project.",
      24,
    ),
    activity(
      [run("Sent the change to the lane", "lane-gh send si-handoff -"), run("Ran the lint", "bun run check")],
      23,
    ),
    assistant(
      "I'm running two helpers in the background:\n\n" +
        "- **Every basic Cloud step**, from creating to deleting, with evidence.\n" +
        "- **Every piece of Swift UI**, sorted into move to Rust or keep in Swift.",
      21,
    ),
    summary(20.8, { status: "completed", durationMs: 142_000, toolCount: 9 }),
  ];
}

/// A reply between two tool groups and nothing else: the shape the test names.
function betweenTwoGroups(): AcpmuxRow[] {
  return [
    user("Make the fetch helper stop retrying client errors", 20),
    activity(
      [
        run("Found the retry loop", "rg -n 'retry' src/net/fetchWithRetry.ts"),
        run("Listed every caller", "rg -l fetchWithRetry src"),
      ],
      19,
    ),
    assistant(
      "The loop retries any response that isn't ok, so a 404 waits through three backoffs before it fails. " +
        "I'm adding a status check there that fails a client error at once and keeps retrying 408 and 429.",
      15,
    ),
    activity(
      [run("Ran the retry tests", "bun test src/net"), run("Checked the branch is clean", "git status --short")],
      10,
    ),
    assistant("Done. The helper now fails a 4xx at once, except 408 and 429, which still retry.", 8),
    summary(7.8, { status: "completed", durationMs: 736_000, toolCount: 4 }),
  ];
}

/// A reply after a background task's notice, and one before another agent's inbox notice.
function aroundNotices(): AcpmuxRow[] {
  return [
    user("Land the build fix", 40),
    activity([run("Started the build", "cmux-ci build --ref HEAD")], 39),
    row("user", 30, {
      text: "Background command finished",
      continues: true,
      incoming: { kind: "notice", text: "Background command finished" },
    } as Partial<AcpmuxRow>),
    assistant(
      "The background build passed, so the fix is safe to land.\n\nI'm sending it for review now and will land it on a pass.",
      29,
    ),
    activity([run("Asked for the review", "router-review manaflow-ai/cmux 37156 --post")], 28),
    assistant("Sent for review. I'll land it when the review passes.", 20),
    summary(19.8, { status: "completed", durationMs: 1_210_000, toolCount: 2 }),
  ];
}

const snapshot = (rows: AcpmuxRow[], family = "claude") => {
  const base = chat(rows, { title: "Turn fold keeps replies", harness: family });
  return { ...base, summary: { ...base.summary!, family } };
};

/// Opens the turn's "Worked for" line.
const openWorked: Play = async (ctx) => {
  const worked = () => ctx.document.querySelector<HTMLElement>(".cv-worked");
  if (worked()?.getAttribute("aria-expanded") === "false") {
    await ctx.click({ selector: ".cv-worked" });
    await ctx.waitFor(() => worked()?.getAttribute("aria-expanded") === "true", { capMs: 10_000 });
  }
};

const variant = (rows: AcpmuxRow[], note: string, family?: string, play?: Play): AgentPaneVariant => ({
  note,
  snapshot: snapshot(rows, family),
  ...(play && { play }),
});

export default agentPaneEntry({
  id: "agent-pane.turn-fold-replies",
  title: "Turn fold keeps replies",
  area: "Agent pane",
  height: 760,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: [
    "agent-session/acpmux/conversation/TurnRows.tsx#WorkedFor",
    "agent-session/acpmux/conversation/TurnRows.tsx#ToolRows",
  ],
  // Each arm closed, then opened: open, the arms draw alike.
  experiment: { definition: turnFoldReplies, script: [{ name: "Open the turn's Worked for", run: openWorked }] },
  variants: {
    "leos-turn": variant(
      leosTurn(),
      "Leo's turn, closed: Worked for, then each reply in place with the work before and after it on its own closed line.",
    ),
    "leos-turn-codex": variant(leosTurn(), "The same turn in a Codex chat: the same replies stay in sight.", "codex"),
    "leos-turn-open": variant(
      leosTurn(),
      "Opened: every run on its own line between the same replies, which do not move.",
      "claude",
      openWorked,
    ),
    "between-two-groups": variant(
      betweenTwoGroups(),
      "A reply between two tool groups, closed: the reply, with one line of work above it and one below.",
    ),
    "around-notices": variant(
      aroundNotices(),
      "A reply after a background task's notice stays in sight under the closed line.",
    ),
  },
});
