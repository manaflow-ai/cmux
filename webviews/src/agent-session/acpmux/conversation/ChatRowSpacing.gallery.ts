// l10n-allow-file: gallery fixtures (sample lanes, messages and commands), not shipped UI.
// Leo, 2026-11-21: "the spacing is just insanely shit here. way too close. no way. we can measure all of these."
// His two captures of one coordinator chat: a "Sent to ..." row running straight into another agent's chip row and
// "Worked for" with no gap, and a blank band between a closed group and the run under it; then the same group
// opened, with uneven bands above its first child and between children. test/chat-row-spacing.test.ts measures each
// pair's gap in Chromium and asserts the table (rowGapTable.test.ts has the model's side of it).
import { agentPaneEntry } from "../../../gallery/format";
import {
  SESSION_ID,
  activity,
  assistant,
  chat,
  row,
  session,
  summary,
  tool,
  user,
} from "../../../gallery/fixtures/acpmux";
import type { AcpmuxActivity, AcpmuxSnapshot } from "../model";

const PEER = "gcp-codex-lane-11";
const send = (to: string, message: string): AcpmuxActivity =>
  tool("SendMessage", "other", "completed", {
    inputSummary: JSON.stringify({ to, message }),
    output: `delivered to ${to}\n`,
  });
const run = (description: string, command: string): AcpmuxActivity =>
  tool(command, "execute", "completed", { description, command, output: "ok\n", exitCode: 0 });
const received = (text: string, minutes: number, id: string) =>
  user(text, minutes, {
    id,
    incoming: {
      kind: "message",
      message: { name: `${PEER}/codex-2`, sessionId: "s-codex", harness: "codex", text, raw: text },
    },
    untyped: true,
  });

function leoChat(): AcpmuxSnapshot {
  const snapshot = chat(
    [
      user("Probe the Macs and report back.", 20, { id: "crs-prompt" }),
      assistant(
        "I'm probing studio-mac, build-box and test-mini, and sending the rows to the census lane when they finish.",
        19,
        {
          id: "crs-reply-1",
        },
      ),
      summary(18.9, { id: "crs-footer-1", status: "completed", durationMs: 18_000, toolCount: 3 }),
      row("backgroundTask", 18, {
        id: "crs-bgtask",
        backgroundTask: { toolCallId: "crs-bg-call", command: "run pool iam.sh --apply", state: "completed" },
      }),
      activity(
        [
          send(`${PEER}/mac-fleet-census`, "The iam.sh --apply run failed."),
          run("Ran the probe", "o=$(echo studio-mac; uptime)"),
          run("Read the rows", "cat rows.json"),
        ],
        17,
        { id: "crs-work-1", inBackground: "crs-bg-1" },
      ),
      received("#48016 handoff accepted. Pushed exact head dceafaa341a after rework.", 16, "crs-recv-1"),
      activity([run("Ran the second probe", "uptime; df -h /")], 15.5, { id: "crs-work-1b", inBackground: "crs-bg-2" }),
      activity([send("goal-next-code-shrinks", "cmux#48016: don't wait for the required checks.")], 15, {
        id: "crs-work-2",
      }),
      assistant("gcp-agent-lane-4 still can't push its leftover edits back. I sent this back with a 1-hour stop.", 14, {
        id: "crs-reply-2",
      }),
      summary(13.9, { id: "crs-footer-2", status: "completed", durationMs: 29_000, toolCount: 4 }),
    ],
    {
      title: "spacing-coordinator",
      sessions: [
        session({ sessionId: SESSION_ID, title: "spacing-coordinator", name: "spacing-coordinator" }),
        session({
          sessionId: "s-codex",
          name: `${PEER}/codex-2`,
          title: "codex-2",
          peer: PEER,
          host: PEER,
          hostKind: undefined,
        }),
      ],
    },
  );
  return { ...snapshot, summary: { ...snapshot.summary!, family: "claude" } };
}

const LOOKS = {
  before:
    "Before: a background turn's first row stands the turn gap (32) under any line, so a blank band opens above an opened group's first child and between its children; \"Worked for\" stands flush under the line above it.",
  tight: 'Candidate A: the lines flush on the 22 pitch, "Worked for" 8 over the line above it.',
  shipped:
    'The pick: the lines flush on the 22 pitch, "Worked for" the run gap (16) over the line above it, as the prose around a run stands.',
  roomy: 'Candidate C: the lines flush on the 22 pitch, "Worked for" the block gap (24) over the line above it.',
} as const;
const openGroup = async (ctx: import("../../../gallery/play").PlayContext) => {
  const head = { selector: ".acpmux-messageRun button" };
  await ctx.click(head);
  await ctx.waitFor(() => ctx.find(head).getAttribute("aria-expanded") === "true");
};
const variants: Record<string, Record<string, unknown>> = {};
for (const [look, note] of Object.entries(LOOKS)) {
  variants[`closed-${look}`] = { note, snapshot: leoChat(), documentAttributes: { "row-gap": look } };
  variants[`open-${look}`] = {
    note: `${note} The group opened.`,
    snapshot: leoChat(),
    documentAttributes: { "row-gap": look },
    checks: {
      layoutShiftMax: {
        value: 0.5,
        reason: "Opening the group intentionally reveals its rows below the clicked line.",
      },
    },
    play: openGroup,
  };
}

export default agentPaneEntry({
  id: "agent-pane.chat-row-spacing",
  title: "Chat row spacing: one-line rows, a group opened, and Worked for",
  area: "Agent pane",
  height: 900,
  covers: [
    "agent-session/acpmux/transcriptGrid.ts",
    "agent-session/acpmux/model.ts",
    "agent-session/acpmux/conversation/conversation.css",
  ],
  variants: variants as never,
});
