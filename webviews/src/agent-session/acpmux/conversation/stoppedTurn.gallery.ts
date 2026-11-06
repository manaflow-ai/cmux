// l10n-allow-file: gallery fixtures (sample prompts and agent messages), not shipped UI.
// A stopped turn (TurnRows.tsx TurnFooter, direct.ts `deferLateSteers`). Leo, 2026-11-03, on a
// coordinator's message drawn above "Continue" and "The agent didn't answer Stop, so cmux ended its
// turn.": "this is an "interesting" recovery flow... idk if it should be showing things like that".
// A Stop acpmux had to force reads as any Stop: a muted "Stopped" in the footer, the reason only in
// its tooltips. A message steered in after the Stop never reached the agent, so it draws below the
// stop, in the order it came; one queued to run next takes Continue away. Compare arms shows the
// `stopped-turn-look` experiment's three footers.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";
import { stoppedTurnLook } from "./stoppedTurn.experiment";

const prompt = "Migrate the parser to the new token stream";

const coordinator = (minutes: number, fields: Parameters<typeof user>[2] = {}) =>
  user("Status check: are you still on the parser migration? Reply with where you are.", minutes, {
    incoming: {
      kind: "message",
      message: {
        name: "coordinator",
        sessionId: "coordinator",
        text: "Status check: are you still on the parser migration? Reply with where you are.",
        raw: "[coordinator] Status check: are you still on the parser migration? Reply with where you are.",
      },
    },
    untyped: true,
    ...fields,
  });

const stoppedTurn = (fields: Parameters<typeof summary>[1] = {}) => [
  user(prompt, 6),
  assistant("The lexer already emits the new tokens. I'm moving the parser's lookahead over next.", 5.5),
  summary(5.3, { status: "cancelled", durationMs: 41_000, ...fields }),
];

export default agentPaneEntry({
  id: "agent-pane.stopped-turn",
  title: "Stopped turn",
  area: "Agent pane",
  height: 280,
  covers: ["agent-session/acpmux/conversation/TurnRows.tsx#TurnFooter"],
  keywords: ["stop", "stopped", "cancel", "continue", "forced", "steer"],
  variants: {
    "forced-stop": {
      note: "acpmux ended the turn because the agent never answered Stop: it reads as any stop; the reason is in the tooltips of Stopped and the time.",
      snapshot: chat(stoppedTurn({ stopForced: true })),
    },
    "person-stop": {
      note: "The person's Stop the agent answered: the same footer.",
      snapshot: chat(stoppedTurn()),
    },
    "forced-stop-message-after": {
      note: "Another agent's message steered in after the Stop never reached the agent: it draws below the stop, and a prompt after the stop takes Continue away.",
      snapshot: chat([...stoppedTurn({ stopForced: true }), coordinator(5.2, { afterStop: true })]),
    },
    "forced-stop-queued-next": {
      note: "acpmux queued that message to run next: its waiting card, and no Continue beside it.",
      snapshot: chat(stoppedTurn({ stopForced: true }), {
        queue: [{ id: "p-late", prompt: "Status check: are you still on the parser migration?", next: true }],
      }),
    },
    before: {
      note: "Before (for comparison): the old notice line under Continue. Not drawn any more.",
      snapshot: chat([
        user(prompt, 6),
        assistant("The lexer already emits the new tokens. I'm moving the parser's lookahead over next.", 5.5),
        coordinator(5.4),
        summary(5.3, { status: "cancelled", durationMs: 41_000 }),
        row("notice", 5.3, { text: "The agent didn't answer Stop, so cmux ended its turn." }),
      ]),
    },
  },
  experiment: {
    definition: stoppedTurnLook,
    // The footer at rest: the last stopped turn's row shows without a pointer.
    script: [{ name: "at rest", run: async () => {} }],
  },
});
