// l10n-allow-file: gallery fixtures (variant notes), not shipped UI.
// A chat's turn lifecycle, one variant per state (turnLifecycle.fixture.ts), each note the state's
// row of the table test/turn-lifecycle-controls.test.tsx checks: Stop with the prompt empty, the
// send control with a draft, Esc, the turn prompt's Edit and the queue's delete. A state reached
// only from another (handover) plays that one first, through the pane's bridge.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { AcpmuxSnapshot } from "./model";
import { TURN_LIFECYCLE, type TurnLifecycleRow } from "./turnLifecycle.fixture";

const yes = (value: boolean) => (value ? "yes" : "no");

function note(row: TurnLifecycleRow): string {
  const { stop, send, escStops, edit, queueDelete } = row.expect;
  return `${row.what} Stop: ${stop}. Draft: ${send}. Esc stops: ${yes(escStops)}. Edit on the turn's prompt: ${yes(edit)}. Queue delete: ${yes(queueDelete)}.`;
}

type Bridge = { receive(snapshot: AcpmuxSnapshot): void };

/** Shows `row.snapshot` after `row.from`, as the pane hears them. */
const reach =
  (row: TurnLifecycleRow): Play =>
  async (ctx) => {
    const bridge = (ctx.document.defaultView as unknown as { cmuxAcpmuxBridge?: Bridge }).cmuxAcpmuxBridge;
    if (!bridge) throw new Error("the pane bridge is not installed");
    bridge.receive(structuredClone(row.snapshot));
    await ctx.waitFor(() => Boolean(ctx.document.querySelector(".acpmux-cancel")) === (row.expect.stop !== "none"));
  };

export default agentPaneEntry({
  id: "agent-pane.turn-lifecycle",
  title: "Turn lifecycle: what each state offers",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 420, normal: 720, wide: 1100 },
  anchors: [{ selector: ".acpmux-composer-box" }, { selector: ".acpmux-composer-bar" }],
  covers: ["agent-session/acpmux/Composer.tsx#Composer", "agent-session/acpmux/conversation/editPrompt.ts"],
  variants: Object.fromEntries(
    TURN_LIFECYCLE.map((row) => [
      row.state,
      row.from
        ? { note: note(row), snapshot: row.from, play: reach(row) }
        : { note: note(row), snapshot: row.snapshot },
    ]),
  ),
});
