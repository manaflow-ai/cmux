// l10n-allow-file: gallery fixtures (sample lane names, messages and commands), not shipped UI.
// A turn another agent's message started, through every state it passes while it runs and when it
// ends (Leo, 2026-11-17, on such a turn: "the jostles and shifts and spacing are still bad here").
// His screenshot: the received line (the sender's mark, its name chip, the message cut to the line
// and a chevron), "Working for 1m 16s" under it, the rule, then "Sent a message, ran 3 commands,
// received 3 messages ›". Each variant is one state of the same turn; the rows that every state
// shares hold the same box in all of them (turn-header-steady-browser.test.ts measures each row's
// top and height across the variants).
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { GALLERY_NOW } from "../../../gallery/clock";
import { activity, chat, row, session, summary, tool, SESSION_ID } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import "./TurnHeaderSpacing.gallery.css";

const SENDER = "ci-watch";
const PROMPT_TEXT =
  "CI on manaflow-ai/cmux#45222 finished at 7e10109: 41 checks green, 2 red (webviews-browser, " +
  "turn-end-fold). Both reds also fail on base; the land queue holds the PR until base is green again.";

const run = (description: string, command: string, status = "completed"): AcpmuxActivity =>
  tool(command, "execute", status, {
    description,
    command,
    output: status === "completed" ? "ok\n" : undefined,
    exitCode: 0,
  });
const send = (to: string, message: string): AcpmuxActivity =>
  tool("SendMessage", "other", "completed", { inputSummary: JSON.stringify({ to, message }) });

/// The message that started the turn: another agent's, delivered by acpmux.
const prompt = (): AcpmuxRow =>
  row("user", 2, {
    id: "steady-prompt",
    text: PROMPT_TEXT,
    incoming: {
      kind: "message",
      message: { name: SENDER, sessionId: "s-ci-watch", text: PROMPT_TEXT, raw: PROMPT_TEXT },
    },
  } as Partial<AcpmuxRow>);

/// Another agent's message that came in while the turn ran.
const received = (id: string, text: string, minutes: number): AcpmuxRow =>
  row("user", minutes, {
    id,
    text,
    continues: true,
    incoming: { kind: "message", message: { name: SENDER, sessionId: "s-ci-watch", text, raw: text } },
  } as Partial<AcpmuxRow>);

/// The turn's work after `steps` steps, as it grows.
function work(steps: number): AcpmuxRow[] {
  const all: AcpmuxRow[] = [
    activity([send(SENDER, "Rerun webviews-browser once base is green.")], 1.9, { id: "steady-send" }),
    received("steady-recv-1", "Queued the rerun.", 1.8),
    activity([run("Checked the PR", "gh pr view 45222 --json state")], 1.7, { id: "steady-run-1" }),
    received("steady-recv-2", "Base is green at 7e10109.", 1.6),
    activity([run("Checked base", "gh pr checks 45222")], 1.5, { id: "steady-run-2" }),
    received("steady-recv-3", "Rerun started.", 1.4),
    activity([run("Watched the rerun", "gh run watch 1873402219")], 1.3, {
      id: "steady-run-3",
    }),
  ];
  return all.slice(0, steps);
}

/// The running turn after `steps` steps, `elapsedMs` since it started.
const running = (steps: number, elapsedMs: number) =>
  chat([prompt(), ...work(steps)], {
    title: "nightly-coordinator",
    isWorking: true,
    turnStartedAtMs: GALLERY_NOW - elapsedMs,
    sessions: [
      session({ sessionId: SESSION_ID, title: "nightly-coordinator", name: "nightly-coordinator" }),
      session({ sessionId: "s-ci-watch", title: SENDER, name: SENDER, harness: "codex" }),
    ],
  });

/// The same turn ended.
const ended = () =>
  chat(
    [
      prompt(),
      ...work(7),
      summary(1.2, { id: "steady-summary", status: "completed", durationMs: 76_000, toolCount: 4 }),
    ],
    {
      title: "nightly-coordinator",
      sessions: [
        session({ sessionId: SESSION_ID, title: "nightly-coordinator", name: "nightly-coordinator" }),
        session({ sessionId: "s-ci-watch", title: SENDER, name: SENDER, harness: "codex" }),
      ],
    },
  );

const variant = (note: string, snapshot: AgentPaneVariant["snapshot"]): AgentPaneVariant => ({ note, snapshot });

/// The room around the rule under the turn's line, in the running and the ended turn: 2 under the
/// words and 6 over the next row (`tight`), the shipped 4 and 8, or 8 and 12 (`roomy`).
const spacing = (look: "tight" | "shipped" | "roomy", note: string): Record<string, AgentPaneVariant> => ({
  [`spacing-${look}`]: {
    ...variant(`${note} Running, 1m 16s in.`, running(7, 76_000)),
    ...(look !== "shipped" && { documentAttributes: { "turn-header-spacing": look } }),
  },
  [`spacing-${look}-ended`]: {
    ...variant(`${note} Ended.`, ended()),
    ...(look !== "shipped" && { documentAttributes: { "turn-header-spacing": look } }),
  },
});

/** The states in the order a turn passes them; the browser test reads them in this order. */
export const TURN_HEADER_STATES = ["started", "first-step", "ticking", "minutes", "counts-grow", "ended"] as const;

export default agentPaneEntry({
  id: "agent-pane.turn-header-steady",
  title: "Turn header holds still",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 420, normal: 640, wide: 900 },
  covers: [
    "agent-session/acpmux/conversation/WorkingFor.tsx#WorkingFor",
    "agent-session/acpmux/conversation/MessageRunLine.tsx#MessageRunLine",
    "agent-session/acpmux/conversation/IncomingMessageCard.tsx",
  ],
  variants: {
    started: variant("The message just came: Working, nothing done yet.", running(0, 400)),
    "first-step": variant("One step: a message sent, 4 s in.", running(1, 4_000)),
    ticking: variant("Two steps, 9 s in: the clock has one digit.", running(3, 9_000)),
    minutes: variant("Five steps, 1m 16s in: the clock reads minutes.", running(5, 76_000)),
    "counts-grow": variant("All seven steps, 1m 16s in: the summary's counts have grown.", running(7, 76_000)),
    ended: variant("The turn ended: Worked for 1m 16s.", ended()),
    ...spacing("tight", "Rule 2 under the words, 6 over the message."),
    ...spacing("shipped", "Rule 4 under the words, 8 over the message (shipped)."),
    ...spacing("roomy", "Rule 8 under the words, 12 over the message."),
  },
});
