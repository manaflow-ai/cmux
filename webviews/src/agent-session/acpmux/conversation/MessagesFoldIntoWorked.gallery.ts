// l10n-allow-file: gallery fixtures (sample prompts, commands, messages and replies), not shipped UI.
// Other agents' messages fold into a finished turn's "Worked for" as regular entries (Leo,
// 2026-11-07, on a "Received 2 messages" row on its own right above a closed "Worked for 1m 17s":
// "Do we want to, like, fold the receiving and sending messages into the worked for as well? Like
// the nearest one? ... Maybe it's fine to count as a regular tool call."). The arms of
// workedForMessages.experiment.ts differ in how the closed line counts them: as calls (shipped: the
// label keeps its time alone), not at all, or named after the time.
// Test: messages-fold-into-worked.test.ts.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { incomingPrompt } from "./incomingMessage";
import { workedForMessages } from "./workedForMessages.experiment";

const run = (description: string, command: string): AcpmuxActivity =>
  tool(command, "execute", "completed", { description, command, output: "ok\n", exitCode: 0 });
const send = (to: string, message: string): AcpmuxActivity =>
  tool("SendMessage", "other", "completed", { inputSummary: JSON.stringify({ to, message }) });

/// acpmux's inbox notice that wakes an idle chat for the messages that came (hub/inbox.rs): the
/// turn's prompt, "Received 2 messages".
function notice(minutes: number): AcpmuxRow {
  const threads = [
    { from: "nightly-watch", text: "The nightly is green at 4910f9a0." },
    { from: "ux-owner", text: "Can I land the sidebar fix on top of it?" },
  ].map(({ from, text }, index) => ({
    threadId: `from:${from}`,
    label: "",
    new: 1,
    from: [from],
    promptIds: [`gallery-wake-${index}`],
    preview: text,
    messages: [{ from, promptId: `gallery-wake-${index}`, text }],
  }));
  const text = [
    "[inbox] New messages from other agents in 2 threads.",
    ...threads.map((thread) => `- 1 new from ${thread.from[0]}: ${thread.preview} (thread ${thread.threadId})`),
  ].join("\n");
  return row("user", minutes, {
    text,
    untyped: true,
    incoming: incomingPrompt(text, {
      client: "acpmux",
      _meta: { provenance: { kind: "inbox_notice", noticeId: "gallery-wake", threads } },
    }) as AcpmuxRow["incoming"],
  } as Partial<AcpmuxRow>);
}

/// Another agent's message that came in while the turn ran (a steer into it).
const received = (name: string, text: string, minutes: number) =>
  row("user", minutes, {
    text,
    continues: true,
    incoming: { kind: "message", message: { name, sessionId: name, text, raw: text } },
  } as Partial<AcpmuxRow>);

/// The person's turn before, then Leo's: the notice wakes the chat; it checks the run, answers one
/// sender, hears back and checks the PR.
function leosTurn(): AcpmuxRow[] {
  return [
    user("Watch the nightly and tell the lanes when it's green", 40),
    activity([run("Listed the nightly runs", "gh run list --workflow nightly")], 39.5),
    assistant("Watching the nightly; I'll tell the lanes when it's green.", 39),
    summary(38.9, { status: "completed", durationMs: 41_000, toolCount: 1 }),
    notice(20),
    activity([run("Checked the nightly", "gh run view 42 --json conclusion")], 19.8),
    activity([send("ux-owner", "Yes, the nightly is green, land it.")], 19.6),
    received("ux-owner", "Thanks, landing now.", 19.4),
    activity([run("Checked the sidebar PR", "gh pr view 37812 --json state")], 19.2),
    assistant("The nightly is green, and the sidebar fix is landing on top of it.", 18.8),
    summary(18.7, { status: "completed", durationMs: 77_000, toolCount: 3 }),
  ];
}

/// The same notice, answered with no work: there is no Worked for to fold it into.
function replyOnly(): AcpmuxRow[] {
  return [
    user("Watch the nightly and tell the lanes when it's green", 40),
    assistant("Watching the nightly.", 39),
    summary(38.9, { status: "completed", durationMs: 4_000, toolCount: 0 }),
    notice(20),
    assistant("Noted: the nightly is green, and the sidebar fix can land on top of it.", 19.8),
    summary(19.7, { status: "completed", durationMs: 6_000, toolCount: 0 }),
  ];
}

const snapshot = (rows: AcpmuxRow[], family: string) => {
  const base = chat(rows, { title: "Messages fold into Worked for", harness: family });
  return { ...base, summary: { ...base.summary!, family } };
};

/// Opens the last turn's "Worked for" line.
const openWorked: Play = async (ctx) => {
  const worked = () => [...ctx.document.querySelectorAll<HTMLElement>(".cv-worked")].at(-1);
  if (worked()?.getAttribute("aria-expanded") === "false") {
    worked()!.click();
    await ctx.waitFor(() => worked()?.getAttribute("aria-expanded") === "true", { capMs: 10_000 });
  }
};

const variant = (rows: AcpmuxRow[], note: string, family = "claude"): AgentPaneVariant => ({
  note,
  snapshot: snapshot(rows, family),
});

export default agentPaneEntry({
  id: "agent-pane.messages-fold-into-worked",
  title: "Messages fold into Worked for",
  area: "Agent pane",
  height: 620,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: ["agent-session/acpmux/conversation/TurnRows.tsx#WorkedFor"],
  // Each arm closed, then opened: open, the arms draw alike.
  experiment: { definition: workedForMessages, script: [{ name: "Open the turn's Worked for", run: openWorked }] },
  variants: {
    "leos-turn": variant(
      leosTurn(),
      "Leo's turn, closed: the notice that woke the chat and the messages beside the calls are under Worked for; the reply stays.",
    ),
    "leos-turn-codex": variant(leosTurn(), "The same turn in a Codex chat.", "codex"),
    "reply-only": variant(
      replyOnly(),
      "A notice answered with no work: no Worked for, so the notice stays in sight as the turn's prompt.",
    ),
  },
});
