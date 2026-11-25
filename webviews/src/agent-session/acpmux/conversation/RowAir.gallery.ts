// l10n-allow-file: gallery fixtures (sample lanes, subagents, messages and commands), not shipped UI.
// Leo, 2026-11-22 10:55Z, on a coordinator chat's activity rows ("started working" chips, "Sent 2 messages",
// thinking lines, a notice, a command) 22 apart beside the newer ChatGPT's tool list, about 33 apart at our size:
// "i dont like it. it's just too much fucking text crammed together. let's just follow the newer chatgpt that his
// this sort of spacing. i dont know about the line before the indent or even the indent, but the spacing... just add
// some more. our is too much of a dense eyesore right now."
// One token, the row air (transcriptGrid.ts ROW_AIR_LOOKS, conversation.css `--cv-row-air`), moves every one-line
// row together; the name chips take a quieter wash (`--cv-chip-bg`, `--cv-chip-ink`). No indent and no guide line.
// Each variant is one look of the same chat, his rows in his order; `before` is what he saw.
import { agentPaneEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import {
  SESSION_ID,
  activity,
  assistant,
  chat,
  row,
  session,
  summary,
  thought,
  tool,
  user,
} from "../../../gallery/fixtures/acpmux";
import type { AcpmuxActivity, AcpmuxRow, AcpmuxSnapshot } from "../model";

const PEER = "studio-mac";
const send = (to: string, message: string): AcpmuxActivity =>
  tool("SendMessage", "other", "completed", {
    inputSummary: JSON.stringify({ to, message }),
    output: `delivered to ${to}\n`,
  });
const run = (description: string, command: string): AcpmuxActivity =>
  tool(command, "execute", "completed", { description, command, output: "ok\n", exitCode: 0 });
const received = (from: string, sessionId: string, text: string, minutes: number, id: string) =>
  user(text, minutes, {
    id,
    incoming: {
      kind: "message",
      message: { name: `${PEER}/${from}`, sessionId, harness: "claude", text, raw: text },
    },
    untyped: true,
  });
let agents = 0;
const subagent = (name: string, task: string, state = "running") => ({
  id: `row-air-agent-${(agents += 1)}`,
  parent: null,
  name,
  task,
  state,
  startedAt: minutesAgo(9),
  ...(state === "completed" && { endedAt: minutesAgo(1), lastMessage: "Done." }),
});
const started = (id: string, minutes: number, ...list: ReturnType<typeof subagent>[]): AcpmuxRow =>
  row("subagentStarted", minutes, { id, subagents: list } as Partial<AcpmuxRow>);
const done = (id: string, minutes: number, agent: ReturnType<typeof subagent>): AcpmuxRow =>
  row("subagentDone", minutes, { id, subagents: [agent] } as Partial<AcpmuxRow>);

function leoChat(): AcpmuxSnapshot {
  const snapshot = chat(
    [
      user("Keep the lanes moving and tell me what lands.", 12, { id: "ra-prompt" }),
      assistant("On it: the iOS audit and two fixes are going out to lanes now.", 11.5, { id: "ra-reply-1" }),
      started("ra-started-1", 11, subagent("iOS placeholder backings audit", "Audit the iOS placeholder backings")),
      activity(
        [
          send("composer-geometry", "Composer geometry, caret, thumb, bottom band"),
          send("unstick-studio-mac", "Unstick studio-mac lanes"),
        ],
        10.5,
        { id: "ra-sends-1" },
      ),
      received(
        "fable-screen-share-arch",
        "s-fable",
        "State: shares from Leo's Mac to a lane go through the relay; plan attached.",
        10,
        "ra-recv-1",
      ),
      activity(
        [
          thought(
            "I'm working through the plan for Leo's video: the jump and the turn-end tool-call shifting, then the composer.",
          ),
        ],
        9.5,
        { id: "ra-think-1" },
      ),
      activity(
        [
          send("fable-dictator", "Fable dictator: no layout shift"),
          send("blacksmith-linux", "Reroute blacksmith-linux waiters"),
        ],
        9,
        { id: "ra-sends-2" },
      ),
      done("ra-done-1", 8.5, subagent("Ask Siri in tab popover", "Ask Siri in tab popover", "completed")),
      received(
        "land-queue",
        "s-glaeda",
        "[notice from land-queue on studio-mac · WARN] land-queue queue stalled on manaflow-ai/cmux#49311",
        8,
        "ra-recv-2",
      ),
      activity(
        [
          thought(
            "I need to deal with the fable-screen-share-arch request, which asks for a Cloudflare log reader on the lane.",
          ),
        ],
        7.5,
        { id: "ra-think-2" },
      ),
      activity([run("Look up who can read Cloudflare worker logs", "wrangler whoami")], 7, { id: "ra-cmd-1" }),
      started(
        "ra-started-2",
        6.5,
        subagent("Fix chat header summary overflow", "Fix the chat header summary overflow"),
        subagent("Subagent controls + fork hammer", "Subagent controls and fork hammer"),
      ),
      done("ra-done-2", 6, subagent("Fable: design system state + plan", "Design system state and plan", "completed")),
      assistant("Three lanes are on it; I'll report when the first one lands.", 5.5, { id: "ra-reply-2" }),
      summary(5.4, { id: "ra-footer", status: "completed", durationMs: 380_000, toolCount: 7 }),
    ],
    {
      title: "claude-sr2-coord",
      sessions: [
        session({ sessionId: SESSION_ID, title: "claude-sr2-coord", name: "claude-sr2-coord" }),
        session({
          sessionId: "s-fable",
          name: `${PEER}/fable-screen-share-arch`,
          title: "fable-screen-share-arch",
          peer: PEER,
          host: PEER,
          hostKind: undefined,
        }),
        session({
          sessionId: "s-glaeda",
          name: `${PEER}/land-queue`,
          title: "land-queue",
          peer: PEER,
          host: PEER,
          hostKind: undefined,
        }),
      ],
    },
  );
  return { ...snapshot, summary: { ...snapshot.summary!, family: "claude" } };
}

const LOOKS: Record<string, { note: string; air: string; chip: string }> = {
  before: {
    note: "Before: rows flush on the 22 pitch, chips on the inset surface in full ink.",
    air: "before",
    chip: "wash",
  },
  a: { note: "Candidate A: 6 of air (a 28 pitch), the quieter chip.", air: "a", chip: "soft" },
  shipped: { note: "The pick: 10 of air (a 32 pitch), the quieter chip.", air: "shipped", chip: "soft" },
  c: { note: "Candidate C: 12 of air (a 34 pitch, ChatGPT's 33), the quieter chip.", air: "c", chip: "soft" },
  "shipped-plain": {
    note: "Candidate D: the pick's 32 pitch, the chips' wash removed.",
    air: "shipped",
    chip: "plain",
  },
};
const variants: Record<string, Record<string, unknown>> = {};
for (const [name, look] of Object.entries(LOOKS))
  variants[name] = {
    note: look.note,
    snapshot: leoChat(),
    documentAttributes: { "row-air": look.air, "chip-look": look.chip },
  };

export default agentPaneEntry({
  id: "agent-pane.row-air",
  title: "Row air: every one-line row's spacing and the name chips' weight",
  area: "Agent pane",
  height: 900,
  covers: [
    "agent-session/acpmux/transcriptGrid.ts",
    "agent-session/acpmux/model.ts",
    "agent-session/acpmux/conversation/conversation.css",
    "agent-session/acpmux/conversation/AgentTag.css",
  ],
  variants: variants as never,
});
