// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// A finished turn's work folds where it ran, and nothing is reordered (Leo, 2026-11-11: "Why is it a
// top-level fold, though? ... it sort of, like, steals commands that came in, perhaps, like, in
// between something, and it just shunts them to the top, like it rewrites the transcript in a way").
// Each run of agent work between two rows that stay in sight (the person's messages, the agent's text
// answers) is its own "Worked for". A steer mid-turn stays where it was sent, a fold on each side. A
// turn a notification woke folds too: his screenshot's "Background command completed", "Stopped",
// "Subagent finished" and "Report from" rows ("Do those not count as the works for?").
// Test: test/turn-fold-keeps-order.test.ts.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { SUBAGENT_DONE } from "../subagents/subagentRows";

const run = (description: string, command: string): AcpmuxActivity =>
  tool(command, "execute", "completed", { description, command, output: "ok\n", exitCode: 0 });

/// A plain turn: work, then the answer.
function plainTurn(): AcpmuxRow[] {
  return [
    user("Why does the retry test flake?", 30),
    activity(
      [
        run("Ran the retry tests", "bun test test/retry.test.ts"),
        run("Read the backoff", "rg -n 'jitter' src/net/backoff.ts"),
        run("Ran the jitter case", "bun test test/retry.test.ts -t jitter"),
      ],
      29.5,
    ),
    assistant(
      "The jitter can push a wait past the backoff's cap, so the third retry sometimes lands after the test's timeout.\n\n" +
        "- Clamp the jitter inside the cap.\n- The test then passes 200 runs in a row.",
      29,
    ),
    summary(28.9, { status: "completed", durationMs: 66_000, toolCount: 3 }),
  ];
}

/// Leo's steered turn: work, his steer mid-turn, more work, the answer.
function steeredTurn(): AcpmuxRow[] {
  return [
    user("Land the fold fix once both builds pass", 30),
    activity(
      [
        run("Started the web build", "cmux-ci build web --ref HEAD"),
        run("Read the fold code", "rg -n 'workStretches' webviews/src"),
        run("Checked the branch", "git status --short"),
      ],
      29.5,
    ),
    user("Also check the nightly before you land", 28, { steer: "landed" }),
    activity(
      [
        run("Listed the nightly runs", "gh run list --workflow nightly-next.yml --limit 3"),
        run("Read the latest nightly", "gh run view --log-failed"),
      ],
      27.5,
    ),
    assistant(
      "The nightly is green and both builds passed. The fold fix is up for review:\n\n" +
        "- Each run of work folds where it ran.\n- Your steer stays where you sent it.",
      26,
    ),
    summary(25.9, { status: "completed", durationMs: 245_000, toolCount: 5 }),
  ];
}

const backgroundEnd = (command: string, state: "completed" | "stopped", minutes: number) =>
  row("backgroundTask", minutes, { backgroundTask: { toolCallId: `call-${minutes}`, command, state } });
const subagentDone = (name: string, minutes: number) =>
  row(SUBAGENT_DONE, minutes, {
    id: `${SUBAGENT_DONE}:${name}`,
    subagents: [{ id: name, name, state: "completed", startedAt: Date.now() - 40 * 60_000 } as never],
  });

/// Leo's screenshot: an answer, then turns background tasks woke (no prompt) that ran commands and
/// heard from subagents, and the next answer.
function wokenTurns(): AcpmuxRow[] {
  return [
    user("Fix the Show more hit area and the attachment spacing", 40),
    activity([run("Started a helper", "acpmux spawn show-more-fix")], 39.5),
    assistant("I'm on it: a helper takes the Show more fix and reads your chats and settings.", 39),
    summary(38.9, { status: "completed", durationMs: 60_000, toolCount: 1 }),
    backgroundEnd("wt new cmux fix--show-more", "completed", 30),
    backgroundEnd("bun test webviews", "stopped", 29),
    subagentDone("Show-more hit area and bubble padding", 28),
    activity([run("Request lane-1 review of #41492", "acpmux send lane-1 review 41492")], 27.5),
    backgroundEnd("wt new checkout completes", "completed", 27),
    backgroundEnd("Wait on wt process then show output", "completed", 26.5),
    summary(26.4, { status: "completed" }),
    assistant(
      "The Show more and attachment spacing fixes are up as #41492 and out for review:\n\n" +
        "- **Show more / Show less:** hovering lights only the words.\n" +
        "- **Attachments in the composer:** the space is now even, 4px on each side.",
      26,
    ),
    summary(25.9, { status: "completed" }),
    backgroundEnd("Fetch base and branch", "completed", 20),
    backgroundEnd("Show fetch result and merge base", "completed", 19),
    subagentDone("Design: what do we need GitHub for", 18),
    backgroundEnd("Check carry chain for new head", "completed", 17),
    summary(16.9, { status: "completed" }),
  ];
}

const snapshot = (rows: AcpmuxRow[], family = "claude") => {
  const base = chat(rows, { title: "Fold in place", harness: family });
  return { ...base, summary: { ...base.summary!, family } };
};

/// Opens the first "Worked for" line on screen.
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
  id: "agent-pane.fold-in-place",
  title: "Turn folds in place",
  area: "Agent pane",
  height: 760,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: [
    "agent-session/acpmux/conversation/turns.ts#shapeTurn",
    "agent-session/acpmux/conversation/TurnRows.tsx#WorkedFor",
  ],
  variants: {
    plain: variant(plainTurn(), "A plain turn: its work folds above the answer, where it ran."),
    "plain-open": variant(plainTurn(), "Opened: the calls in place, the answer under them.", "claude", openWorked),
    steered: variant(
      steeredTurn(),
      "A steer mid-turn: a fold before it, the steer where Leo sent it, a fold after it, the answer.",
    ),
    "steered-open": variant(
      steeredTurn(),
      "Opened: both folds open in place; the steer never moves to the top.",
      "claude",
      openWorked,
    ),
    "steered-codex": variant(steeredTurn(), "The same steered turn in a Codex chat: the same two folds.", "codex"),
    "notification-woken": variant(
      wokenTurns(),
      "Leo's screenshot: background command ends, stops and subagent reports between two answers fold into one Worked for each.",
    ),
    "notification-woken-open": variant(
      wokenTurns(),
      "Opened: the woken turns' rows in the order they came.",
      "claude",
      openWorked,
    ),
  },
});
