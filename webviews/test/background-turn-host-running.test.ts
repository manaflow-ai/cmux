// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Leo, 2026-11-22: "IF THIS IS THE CASE, THEN DON'T FUCKING DISPLAY THIS BULLSHIT LIKE THIS" and
// "WHAT THE HELL? WHY DID IT FUCKING DISPLAY NOTHING THEN COPY BUTTONS THEN YOU SENT SHIT THEN MY
// STEER WENT UNDER IT THEN FUCKKKK". A turn ended on its reply and footer; a background command's end
// then woke the agent (a `background_turn`), and acpmux's summary said a turn runs. The pane took
// that for its prompt's ended turn going on: it opened it again and drew a `typing` row under the
// footer, an empty band with the running turn's footer under it, and Leo's next prompt went under
// both. The turn acpmux runs then is the background one, which draws in its own line.
import { expect, test } from "bun:test";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { connect, fakeDaemon, record, type Step } from "./support/agentPairDaemon";

const update = (update: Record<string, unknown>) => ({ method: "session/update", params: { update } });
const say = (text: string): Step => [
  "in",
  "agent_message_chunk",
  update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
];
const call = (id: string, title: string): Step => [
  "in",
  "tool_call",
  update({ sessionUpdate: "tool_call", toolCallId: id, title, kind: "execute", status: "completed" }),
];

const prompt: Step[] = [
  ["mux", "user_message", { text: "Give every lane a helper", turnId: "t1" }],
  ["mux", "turn_started", { turnId: "t1" }],
  call("send", "SendMessage"),
  say("All six now have a helper."),
  ["mux", "turn_result", { turnId: "t1", status: "completed" }],
];
const woke: Step = ["mux", "background_turn", { state: "started", id: "bg-1", trigger: "system" }];
const background: Step[] = [call("check", "Check the broker"), say("The broker answers again.")];
const ended: Step = ["mux", "background_turn", { state: "ended", id: "bg-1", trigger: "system", quiet: true }];

for (const named of [undefined, "bg-1", "acp-turn-7"])
  test(`a background turn acpmux says runs (${named ?? "unnamed"}) draws no empty row under the ended turn`, async () => {
    const steps = [...prompt, woke];
    const history = record(steps);
    const daemon = fakeDaemon(history);
    const { client, rows } = await connect(daemon);
    try {
      const view = () => turnView(rows(), new Set()).filter((row) => row.kind !== "date") as AcpmuxRow[];
      const typing = () => rows().some((row) => row.kind === "typing");
      // While the background turn runs, and once it ends: the prompt's turn stays ended.
      daemon.changed({ status: "running", turn: named ? { turnId: named } : {} });
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(typing()).toBe(false);
      daemon.push(record(background, history.length + 1));
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(typing()).toBe(false);
      expect(
        view()
          .filter((row) => row.kind === "turnSummary")
          .map((row) => row.id),
      ).toEqual(["summary-t1"]);
      daemon.push(record([ended], history.length + 1));
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(typing()).toBe(false);

      // The prompt's turn keeps its one footer; the background turn's own (`backgroundEnd-`) is its line's.
      const footers = view().filter((row) => row.kind === "turnSummary" && !row.id.startsWith("backgroundEnd-"));
      expect(footers.map((row) => row.id)).toEqual(["summary-t1"]);

      daemon.changed({ status: "idle", turn: null });
      daemon.push(record([["mux", "user_message", { text: "Is the broker up?", turnId: "t2" }]], history.length + 1));
      await new Promise((resolve) => setTimeout(resolve, 0));
      const drawn = view();
      const next = drawn.findIndex((row) => row.kind === "user" && row.text === "Is the broker up?");
      // The prompt follows the background turn's line, with no empty row or second footer between.
      const between = drawn.slice(drawn.findIndex((row) => row.id === footers[0]!.id) + 1, next);
      expect(between.map((row) => row.kind)).not.toContain("typing");
      expect(between.filter((row) => row.kind === "turnSummary" && !row.id.startsWith("backgroundEnd-"))).toEqual([]);
    } finally {
      client.close();
    }
  });
