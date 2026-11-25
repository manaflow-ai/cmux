// l10n-allow-file: gallery fixtures (sample prompts, commands, messages and replies), not shipped UI.
// ST-02. Leo, 2026-11-22 08:29Z (screenshot 1159: an opened "Worked for 7s", then "claude-sr2-coord ..." and
// "Sent to Map all chat stream edge cases" under it with a band over them): "this one seems to have an unnecessary
// gap due to being a recieved message. these aren't categorized properly under our tool call formatting." Earlier,
// 05:14Z: "sometimes you get these way-too-big gaps. i think it's the message recieving not properly getting treated
// like the tool call ish thing it should be".
//
// Every activity row kind on one 22px pitch, in a running turn and in a finished turn's opened "Worked for": a tool
// run, another agent's message received mid-turn, the message that opened the turn (folded in as the fold's first
// entry), a "Sent to" line, a notice and a tool run again. Each stands the gap a tool row stands in its place
// (transcriptGrid.ts transcriptGap; model.ts headsIncomingTurn). Draw it light, dark and over a picture (glass):
// the gallery's Appearance and Background controls (env.ts colorScheme, BACKGROUNDS).
// Tests: test/received-sent-activity-gap.test.ts; the sim scenario `received-sent-as-activity` (test/chat-sim.test.ts).
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { incomingPrompt } from "./incomingMessage";

const run = (description: string, command: string): AcpmuxActivity =>
  tool(command, "execute", "completed", { description, command, output: "ok\n", exitCode: 0 });
const send = (to: string, message: string): AcpmuxActivity => run(`Sent to ${to}`, `acpmux send ${to} '${message}'`);

/// Another agent's message: the turn's prompt (`opens`), or steered into the running turn.
const message = (name: string, text: string, minutes: number, opens = false): AcpmuxRow =>
  row("user", minutes, {
    text,
    ...(opens
      ? {
          untyped: true,
          incoming: incomingPrompt(text, {
            client: "acpmux-peer#gallery",
            _meta: { provenance: { kind: "agent_message", from: "fromAgent", fromName: name, fromSessionId: name } },
          }) as AcpmuxRow["incoming"],
        }
      : {
          continues: true,
          incoming: { kind: "message", message: { name, sessionId: name, text, raw: text } },
        }),
  } as Partial<AcpmuxRow>);

/// A notice from another lane (a merge, a finished task), steered into the running turn.
const notice = (name: string, title: string, minutes: number): AcpmuxRow =>
  row("user", minutes, {
    text: title,
    continues: true,
    incoming: {
      kind: "notice",
      notice: { sender: name, severity: "info", title },
      message: { name, sessionId: name, text: title, raw: title },
    } as unknown as AcpmuxRow["incoming"],
  } as Partial<AcpmuxRow>);

const before = (): AcpmuxRow[] => [
  user("Map all chat stream edge cases with your helper", 30),
  activity([send("map-edge-cases", "Map all chat stream edge cases.")], 29.8),
  assistant("Started the helper; it maps the stream's edge cases.", 29.6),
  summary(29.5, { status: "completed", durationMs: 7_000, toolCount: 1 }),
];

/// Leo's 1159: another agent's message opens a turn that sends one and replies.
const leos1159 = (): AcpmuxRow[] => [
  ...before(),
  message("claude-sr2-coord", "chat-scenarios: no lane of mine holds it; it's yours.", 10, true),
  activity([send("map-edge-cases", "claude-sr2-coord says chat-scenarios is ours; carry on.")], 9.9),
  assistant(
    "Got it, thanks. My helper owns chat-scenarios, covering the stream edge cases as well as the oddities.",
    9.8,
  ),
  summary(9.7, { status: "completed", durationMs: 7_000, toolCount: 1 }),
];

/// Every activity row kind between a turn's calls.
const everyKind = (ended: boolean): AcpmuxRow[] => [
  ...before(),
  user("Check on both helpers and land what's ready", 10),
  activity([run("Listed the helpers", "acpmux ls --json")], 9.9),
  message("visible-under-load", "The numbers: p95 frame 9 ms under load.", 9.8),
  activity([send("visible-under-load", "Thanks, land it.")], 9.7),
  notice("merge-bot", "cmux#49992 merged", 9.6),
  activity([run("Pulled the base", "git pull --ff-only")], 9.5),
  activity([send("map-edge-cases", "Base moved; rebase when you can.")], 9.4),
  ...(ended
    ? [
        assistant("Both helpers have their next steps, and the under-load fix is landing.", 9.2),
        summary(9.1, { status: "completed", durationMs: 48_000, toolCount: 4 }),
      ]
    : []),
];

/// Opens the last turn's "Worked for" line.
const openWorked: Play = async (ctx) => {
  const worked = () => [...ctx.document.querySelectorAll<HTMLElement>(".cv-worked")].at(-1);
  if (worked()?.getAttribute("aria-expanded") === "false") {
    worked()!.click();
    await ctx.waitFor(() => worked()?.getAttribute("aria-expanded") === "true", { capMs: 10_000 });
  }
};

const variant = (rows: AcpmuxRow[], note: string, working = false, play?: Play): AgentPaneVariant => ({
  note,
  snapshot: chat(rows, { title: "coord", ...(working && { isWorking: true }) }),
  ...(play && { play }),
});

export default agentPaneEntry({
  id: "agent-pane.received-sent-activity",
  title: "Received and sent messages as activity rows",
  area: "Agent pane",
  height: 620,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: ["agent-session/acpmux/model.ts#headsIncomingTurn", "agent-session/acpmux/transcriptGrid.ts#transcriptGap"],
  variants: {
    "leos-1159-opened": variant(
      leos1159(),
      "Leo's 1159, its Worked for opened: the message that opened the turn is the fold's first entry, flush under the rule as a tool row is, then \"Sent to\" on the 22px pitch.",
      false,
      openWorked,
    ),
    "leos-1159-closed": variant(
      leos1159(),
      "The same turn closed: Worked for, the reply and its footer; the message and the send are under the line.",
    ),
    "every-kind-running": variant(
      everyKind(false),
      'A running turn: a call, a received message, "Sent to", a notice, a call and "Sent to", one 22px row apart, the live line under them.',
      true,
    ),
    "every-kind-opened": variant(
      everyKind(true),
      "The same turn ended, its Worked for opened: the rows keep the pitch they had while it ran.",
      false,
      openWorked,
    ),
  },
});
